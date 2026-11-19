import Foundation

/// Errors from the `ar_bridge` HTTP surface. See `docs/protocols/ar_bridge_http.md`.
public enum ARBridgeError: Error, Equatable, Sendable {
    case invalidURI(String)
    case badRequest(String)
    case notFound(String)
    case unsupportedFormat(String)
    case payloadTooLarge(String)
    case notImplemented(String)
    case serverError(status: Int, message: String)
    case transport(String)
    case missingSHA256Header
    case malformedResponse(String)
}

public enum CloudUploadMode: String, Sendable {
    case replace, append
}

/// The `{"points", "file", "topic"}` body `POST /v0/cloud` returns on success.
public struct CloudUploadResult: Sendable, Equatable, Decodable {
    public let points: Int
    public let file: String
    public let topic: String
}

/// A mesh fetched from `ar_bridge`: always Wavefront OBJ bytes (see protocol doc for why), plus
/// the SOURCE file's sha256 — the same hash convention the bundled-mesh manifest uses, so all
/// three `MeshProvider` tiers agree on what "the same mesh" means.
public struct FetchedMesh: Sendable, Equatable {
    public let data: Data
    public let sourceSHA256: String

    public init(data: Data, sourceSHA256: String) {
        self.data = data
        self.sourceSHA256 = sourceSHA256
    }
}

/// Client for the `ar_bridge` companion node's HTTP surface. One client per connection; `baseURL`
/// is typically `http://<rosbridge host>:8765` (fixed port, same host the user already entered).
public struct ARBridgeClient: Sendable {
    public let baseURL: URL
    private let transport: HTTPTransport

    public init(baseURL: URL, transport: HTTPTransport = URLSessionHTTPTransport()) {
        self.baseURL = baseURL
        self.transport = transport
    }

    /// `GET /v0/mesh?uri=package://pkg/path`.
    public func fetchMesh(uri: String) async throws -> FetchedMesh {
        let url = try makeURL(path: "/v0/mesh", queryItems: [URLQueryItem(name: "uri", value: uri)])
        let response = try await perform { try await transport.get(url) }

        switch response.statusCode {
        case 200:
            guard let sha = response.header("X-Mesh-SHA256") else {
                throw ARBridgeError.missingSHA256Header
            }
            return FetchedMesh(data: response.data, sourceSHA256: sha)
        case 400:
            throw ARBridgeError.invalidURI(bodyText(response))
        case 404:
            throw ARBridgeError.notFound(bodyText(response))
        case 415:
            throw ARBridgeError.unsupportedFormat(bodyText(response))
        case 501:
            throw ARBridgeError.notImplemented(bodyText(response))
        default:
            log.error("mesh fetch for \(uri, privacy: .public) got unexpected status \(response.statusCode)")
            throw ARBridgeError.serverError(status: response.statusCode, message: bodyText(response))
        }
    }

    /// `POST /v0/cloud` — body is binary PLY (`LiDARScan.PLYCodec.encode`). `frameId` is the
    /// frame the points are already expressed in — see `docs/protocols/ar_bridge_http.md` for
    /// the `base_link`/`map` convention this app's caller follows pre-M4.
    public func uploadCloud(
        _ data: Data, frameId: String, name: String? = nil, mode: CloudUploadMode = .replace
    ) async throws -> CloudUploadResult {
        var query = [
            URLQueryItem(name: "frame_id", value: frameId),
            URLQueryItem(name: "mode", value: mode.rawValue),
        ]
        if let name {
            query.append(URLQueryItem(name: "name", value: name))
        }
        let url = try makeURL(path: "/v0/cloud", queryItems: query)
        let response = try await perform { try await transport.post(url, body: data) }

        switch response.statusCode {
        case 200:
            do {
                return try JSONDecoder().decode(CloudUploadResult.self, from: response.data)
            } catch {
                throw ARBridgeError.malformedResponse("\(error)")
            }
        case 400:
            throw ARBridgeError.badRequest(bodyText(response))
        case 413:
            throw ARBridgeError.payloadTooLarge(bodyText(response))
        case 501:
            throw ARBridgeError.notImplemented(bodyText(response))
        default:
            log.error("cloud upload got unexpected status \(response.statusCode)")
            throw ARBridgeError.serverError(status: response.statusCode, message: bodyText(response))
        }
    }

    /// `DELETE /v0/cloud[?name=]` — the app's Clear: ar_bridge drops the stored scan, publishes
    /// an empty cloud (RViz/MoveIt empty too) and clears MoveIt's octomap.
    public func clearCloud(name: String? = nil) async throws {
        let url = try makeURL(path: "/v0/cloud", queryItems: name.map { [URLQueryItem(name: "name", value: $0)] } ?? [])
        let response = try await perform { try await transport.delete(url) }
        switch response.statusCode {
        case 200: return
        case 501: throw ARBridgeError.notImplemented(bodyText(response))
        default:
            log.error("cloud clear got unexpected status \(response.statusCode)")
            throw ARBridgeError.serverError(status: response.statusCode, message: bodyText(response))
        }
    }

    /// `GET /health`.
    public func health() async throws -> ARBridgeHealth {
        let url = baseURL.appendingPathComponent("health")
        let response = try await perform { try await transport.get(url) }
        guard response.statusCode == 200 else {
            throw ARBridgeError.serverError(status: response.statusCode, message: bodyText(response))
        }
        return try JSONDecoder().decode(ARBridgeHealth.self, from: response.data)
    }

    // MARK: - Shared

    /// Absolute path, never joined onto whatever `baseURL.path` is: `NSString.appendingPathComponent`
    /// on an empty base (`baseURL` has no path, e.g. "http://host:8765") omits the leading "/",
    /// which makes `URLComponents.url` return nil for a URL with an authority component.
    private func makeURL(path: String, queryItems: [URLQueryItem]) throws -> URL {
        guard var components = URLComponents(url: baseURL, resolvingAgainstBaseURL: false) else {
            throw ARBridgeError.transport("invalid base URL \(baseURL)")
        }
        components.path = components.path.isEmpty ? path : components.path + path
        components.queryItems = queryItems
        guard let url = components.url else {
            throw ARBridgeError.transport("could not build URL for \(path)")
        }
        return url
    }

    private func perform(_ call: () async throws -> HTTPResponse) async throws -> HTTPResponse {
        do {
            return try await call()
        } catch let e as ARBridgeError {
            throw e
        } catch {
            log.error("transport error: \(String(describing: error), privacy: .public)")
            throw ARBridgeError.transport(String(describing: error))
        }
    }

    private func bodyText(_ response: HTTPResponse) -> String {
        String(decoding: response.data, as: UTF8.self)
    }
}

public struct ARBridgeHealth: Decodable, Sendable, Equatable {
    public let ok: Bool
    public let node: String
    public let protocolVersion: Int
    public let rosDistro: String

    enum CodingKeys: String, CodingKey {
        case ok, node
        case protocolVersion = "protocol"
        case rosDistro = "ros_distro"
    }
}
