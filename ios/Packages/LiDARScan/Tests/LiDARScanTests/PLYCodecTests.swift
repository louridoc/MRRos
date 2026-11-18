import Foundation
@testable import LiDARScan
import Testing

struct PLYCodecTests {
    private func close(_ a: Float, _ b: Float, tol: Float = 1e-5) -> Bool {
        abs(a - b) < tol
    }

    @Test func roundTripXYZOnly() throws {
        let cloud = PointCloud(x: [1, -2.5, 0], y: [0.1, 2, -3], z: [5, -5.5, 0.25])
        let data = PLYCodec.encode(cloud)
        let back = try PLYCodec.decode(data)
        #expect(back.x == cloud.x)
        #expect(back.y == cloud.y)
        #expect(back.z == cloud.z)
        #expect(back.confidence == nil)
        #expect(back.color == nil)
    }

    @Test func roundTripWithConfidenceOnly() throws {
        let cloud = PointCloud(x: [1, 2], y: [3, 4], z: [5, 6], confidence: [0, 2])
        let back = try PLYCodec.decode(PLYCodec.encode(cloud))
        #expect(back.confidence == [0, 2])
        #expect(back.color == nil)
    }

    @Test func roundTripWithColorOnly() throws {
        let cloud = PointCloud(x: [1], y: [2], z: [3], color: [SIMD3(255, 10, 0)])
        let back = try PLYCodec.decode(PLYCodec.encode(cloud))
        #expect(back.color == [SIMD3<UInt8>(255, 10, 0)])
        #expect(back.confidence == nil)
    }

    @Test func roundTripWithConfidenceAndColor() throws {
        let cloud = PointCloud(
            x: [1, -1], y: [2, -2], z: [3, -3],
            confidence: [1, 2], color: [SIMD3(10, 20, 30), SIMD3(40, 50, 60)]
        )
        let back = try PLYCodec.decode(PLYCodec.encode(cloud))
        #expect(back == cloud)
    }

    @Test func roundTripEmptyCloud() throws {
        let back = try PLYCodec.decode(PLYCodec.encode(.empty))
        #expect(back.count == 0)
    }

    @Test func roundTripManyPointsPreservesValuesWithinFloatPrecision() throws {
        var x: [Float] = [], y: [Float] = [], z: [Float] = []
        for i in 0 ..< 10000 {
            x.append(Float(i) * 0.001 - 5)
            y.append(sin(Float(i)))
            z.append(cos(Float(i)))
        }
        let cloud = PointCloud(x: x, y: y, z: z)
        let back = try PLYCodec.decode(PLYCodec.encode(cloud))
        #expect(back.count == 10000)
        for i in stride(from: 0, to: 10000, by: 777) {
            #expect(close(back.x[i], cloud.x[i]))
            #expect(close(back.y[i], cloud.y[i]))
            #expect(close(back.z[i], cloud.z[i]))
        }
    }

    @Test func encodedHeaderMatchesTheDocumentedFormatExactly() {
        let cloud = PointCloud(x: [1], y: [2], z: [3], confidence: [9])
        let data = PLYCodec.encode(cloud)
        let text = String(decoding: data.prefix(200), as: UTF8.self)
        #expect(text.hasPrefix("ply\nformat binary_little_endian 1.0\n"))
        #expect(text.contains("element vertex 1\n"))
        #expect(text.contains("property float x\nproperty float y\nproperty float z\n"))
        #expect(text.contains("property uchar confidence\n"))
        #expect(!text.contains("red")) // no color on this cloud
        #expect(text.contains("end_header\n"))
    }

    @Test func encodesLittleEndianBytesExactly() {
        // A single point with a known float bit pattern, checked byte-for-byte — not just
        // "decode(encode(x)) == x", which could hide a consistent-but-wrong endianness bug.
        let cloud = PointCloud(x: [1.0], y: [-1.0], z: [0.0])
        let data = PLYCodec.encode(cloud)
        let body = Array(data.suffix(12)) // 3 × float32, no confidence/color
        #expect(body[0 ..< 4] == [0x00, 0x00, 0x80, 0x3F]) // 1.0f LE
        #expect(body[4 ..< 8] == [0x00, 0x00, 0x80, 0xBF]) // -1.0f LE
        #expect(body[8 ..< 12] == [0x00, 0x00, 0x00, 0x00]) // 0.0f
    }

    @Test func decodesAHandWrittenFileIndependentOfOurOwnEncoder() throws {
        // Two points, xyz + confidence, assembled by hand to prove the decoder isn't just the
        // mirror image of our own encoder (a real interop check).
        var bytes = Data("ply\nformat binary_little_endian 1.0\nelement vertex 2\n".utf8)
        bytes += Data(
            "property float x\nproperty float y\nproperty float z\nproperty uchar confidence\nend_header\n"
                .utf8
        )
        func f32(_ v: Float) -> [UInt8] {
            withUnsafeBytes(of: v.bitPattern.littleEndian) { Array($0) }
        }
        bytes += f32(1) + f32(2) + f32(3) + [200]
        bytes += f32(-1) + f32(-2) + f32(-3) + [1]

        let cloud = try PLYCodec.decode(bytes)
        #expect(cloud.x == [1, -1])
        #expect(cloud.y == [2, -2])
        #expect(cloud.z == [3, -3])
        #expect(cloud.confidence == [200, 1])
    }

    @Test func rejectsMissingMagic() {
        let bad = Data("nope\nformat binary_little_endian 1.0\nelement vertex 0\nend_header\n".utf8)
        #expect(throws: PLYError.malformedHeader("missing 'ply' magic line")) {
            _ = try PLYCodec.decode(bad)
        }
    }

    @Test func rejectsWrongFormat() {
        let bad = Data("ply\nformat ascii 1.0\nelement vertex 0\nend_header\n".utf8)
        #expect(throws: PLYError.malformedHeader("expected 'format binary_little_endian 1.0'")) {
            _ = try PLYCodec.decode(bad)
        }
    }

    @Test func rejectsMissingEndHeader() {
        let bad = Data("ply\nformat binary_little_endian 1.0\nelement vertex 0\n".utf8)
        #expect(throws: PLYError.malformedHeader("missing end_header")) {
            _ = try PLYCodec.decode(bad)
        }
    }

    @Test func rejectsUnsupportedPropertyOrder() {
        // color declared without xyz first — never produced by us, must not be silently misread.
        let bad = Data(
            "ply\nformat binary_little_endian 1.0\nelement vertex 1\nproperty uchar red\nend_header\n\u{0}"
                .utf8
        )
        #expect(throws: PLYError.unsupportedProperties(["red"])) {
            _ = try PLYCodec.decode(bad)
        }
    }

    @Test func rejectsTruncatedBody() {
        var bytes = Data("ply\nformat binary_little_endian 1.0\nelement vertex 2\n".utf8)
        bytes += Data("property float x\nproperty float y\nproperty float z\nend_header\n".utf8)
        bytes += Data(repeating: 0, count: 12) // only 1 vertex worth of bytes, claimed 2
        #expect(throws: PLYError.unexpectedEOF(expected: 24, got: 12)) {
            _ = try PLYCodec.decode(bytes)
        }
    }

    @Test func smallCloudHeaderDoesNotTriggerFalseASCIIFailure() throws {
        // Regression: an earlier version decoded `data.prefix(4096)` as ASCII to find the
        // header, which broke for any small cloud whose binary payload (almost never valid
        // ASCII) fell inside that window. A 1-point cloud's total size is far under 4096 bytes.
        let cloud = PointCloud(x: [-123.456], y: [0.0001], z: [999.9])
        let back = try PLYCodec.decode(PLYCodec.encode(cloud))
        #expect(close(back.x[0], cloud.x[0]))
    }
}
