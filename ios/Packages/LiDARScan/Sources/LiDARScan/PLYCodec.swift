import Foundation

/// Binary little-endian PLY, encode/decode. Matches `docs/protocols/ar_bridge_http.md`'s
/// `POST /v0/cloud` body exactly, and `ar_bridge`'s Python-side reader — if this format changes,
/// update `ros2_ws/src/ar_bridge/ar_bridge/ply.py` in the same commit.
///
/// Supported shape (checked, not assumed): `x y z` float32 always; `confidence` uint8 optional;
/// `red green blue` uint8 optional; any other property list is rejected rather than silently
/// misread. This is a real, minimal, standards-conformant PLY (openable in MeshLab/CloudCompare/
/// open3d), not a private format that merely looks like one.
public enum PLYError: Error, Equatable, Sendable {
    case malformedHeader(String)
    case unsupportedProperties([String])
    case unexpectedEOF(expected: Int, got: Int)
    case countMismatch(property: String, vertices: Int, got: Int)
}

public enum PLYCodec {
    private static let magic = "ply\n"
    private static let formatLine = "format binary_little_endian 1.0\n"

    // MARK: - Encode

    public static func encode(_ cloud: PointCloud) -> Data {
        let n = cloud.count
        var header = magic + formatLine + "comment MRRos static scan\n" + "element vertex \(n)\n"
        header += "property float x\nproperty float y\nproperty float z\n"
        if cloud.confidence != nil {
            header += "property uchar confidence\n"
        }
        if cloud.color != nil {
            header += "property uchar red\nproperty uchar green\nproperty uchar blue\n"
        }
        header += "end_header\n"

        let stride = rowStride(hasConfidence: cloud.confidence != nil, hasColor: cloud.color != nil)
        var body = Data(capacity: n * stride)
        for i in 0 ..< n {
            withUnsafeBytes(of: cloud.x[i].bitPattern.littleEndian) { body.append(contentsOf: $0) }
            withUnsafeBytes(of: cloud.y[i].bitPattern.littleEndian) { body.append(contentsOf: $0) }
            withUnsafeBytes(of: cloud.z[i].bitPattern.littleEndian) { body.append(contentsOf: $0) }
            if let confidence = cloud.confidence {
                body.append(confidence[i])
            }
            if let color = cloud.color {
                body.append(color[i].x)
                body.append(color[i].y)
                body.append(color[i].z)
            }
        }
        return Data(header.utf8) + body
    }

    // MARK: - Decode

    public static func decode(_ data: Data) throws -> PointCloud {
        let (vertexCount, properties, headerEnd) = try parseHeader(data)
        let hasConfidence = properties.contains("confidence")
        let hasColor = properties.contains("red")
        let stride = rowStride(hasConfidence: hasConfidence, hasColor: hasColor)
        let expectedBytes = vertexCount * stride
        let body = data[headerEnd...]
        guard body.count >= expectedBytes else {
            throw PLYError.unexpectedEOF(expected: expectedBytes, got: body.count)
        }

        var xs = [Float](repeating: 0, count: vertexCount)
        var ys = [Float](repeating: 0, count: vertexCount)
        var zs = [Float](repeating: 0, count: vertexCount)
        var confidences: [UInt8]? = hasConfidence ? [UInt8](repeating: 0, count: vertexCount) : nil
        var colors: [SIMD3<UInt8>]? = hasColor ? [SIMD3<UInt8>](repeating: .zero, count: vertexCount) : nil

        body.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
            var offset = 0
            for i in 0 ..< vertexCount {
                xs[i] = Float(bitPattern: UInt32(littleEndian: raw.loadUnaligned(
                    fromByteOffset: offset,
                    as: UInt32.self
                )))
                offset += 4
                ys[i] = Float(bitPattern: UInt32(littleEndian: raw.loadUnaligned(
                    fromByteOffset: offset,
                    as: UInt32.self
                )))
                offset += 4
                zs[i] = Float(bitPattern: UInt32(littleEndian: raw.loadUnaligned(
                    fromByteOffset: offset,
                    as: UInt32.self
                )))
                offset += 4
                if hasConfidence {
                    confidences![i] = raw.loadUnaligned(fromByteOffset: offset, as: UInt8.self)
                    offset += 1
                }
                if hasColor {
                    let r = raw.loadUnaligned(fromByteOffset: offset, as: UInt8.self)
                    let g = raw.loadUnaligned(fromByteOffset: offset + 1, as: UInt8.self)
                    let b = raw.loadUnaligned(fromByteOffset: offset + 2, as: UInt8.self)
                    colors![i] = SIMD3(r, g, b)
                    offset += 3
                }
            }
        }
        return PointCloud(x: xs, y: ys, z: zs, confidence: confidences, color: colors)
    }

    // MARK: - Shared

    private static func rowStride(hasConfidence: Bool, hasColor: Bool) -> Int {
        12 + (hasConfidence ? 1 : 0) + (hasColor ? 3 : 0)
    }

    /// Returns (vertexCount, propertyNames in declared order, byte offset right after `end_header\n`).
    ///
    /// Only the header bytes are ever decoded as text: the binary payload that follows is NOT
    /// ASCII in general (most float32/uint8 byte values have the high bit set), so this must
    /// locate the literal `end_header\n` marker by searching raw bytes first, never by decoding
    /// some fixed-size prefix of the whole file as a string (that fails for any small cloud,
    /// where the prefix window reaches into the binary payload).
    private static func parseHeader(_ data: Data) throws -> (Int, [String], Int) {
        let marker = Data("end_header\n".utf8)
        guard let markerRange = data.range(of: marker) else {
            throw PLYError.malformedHeader("missing end_header")
        }
        let headerEnd = markerRange.upperBound
        guard let headerText = String(data: data[..<headerEnd], encoding: .ascii) else {
            throw PLYError.malformedHeader("header is not ASCII")
        }

        // Only "\n" line endings are produced or accepted: this encoder/decoder pair are each
        // other's only real consumer (plus ar_bridge's own Python reader), so there is no third
        // party's CRLF file to tolerate, and tolerating it correctly would mean re-deriving byte
        // offsets per stripped "\r" — not worth the risk for a format nothing else writes.
        let lines = headerText.split(separator: "\n", omittingEmptySubsequences: false)
        guard lines.first == "ply" else {
            throw PLYError.malformedHeader("missing 'ply' magic line")
        }
        guard lines.count > 1, lines[1] == "format binary_little_endian 1.0" else {
            throw PLYError.malformedHeader("expected 'format binary_little_endian 1.0'")
        }

        var vertexCount: Int?
        var properties: [String] = []
        for line in lines {
            if line.hasPrefix("comment") || line == "ply" || line
                .hasPrefix("format") || line == "end_header"
            {
                continue
            }
            if line.hasPrefix("element vertex") {
                vertexCount = Int(line.split(separator: " ").last ?? "")
            } else if line.hasPrefix("property"), let name = line.split(separator: " ").last {
                properties.append(String(name))
            }
        }
        guard let n = vertexCount else { throw PLYError.malformedHeader("missing 'element vertex'") }
        try validate(properties)
        return (n, properties, headerEnd)
    }

    /// Must be exactly x,y,z, then optionally confidence, then optionally red,green,blue — in
    /// that order. Anything else is rejected rather than guessed at.
    private static func validate(_ properties: [String]) throws {
        var expected = ["x", "y", "z"]
        var rest = properties
        guard rest.count >= 3, Array(rest.prefix(3)) == expected else {
            throw PLYError.unsupportedProperties(properties)
        }
        rest.removeFirst(3)
        if rest.first == "confidence" {
            rest.removeFirst()
        }
        if !rest.isEmpty {
            expected = ["red", "green", "blue"]
            guard rest == expected else { throw PLYError.unsupportedProperties(properties) }
        }
    }
}
