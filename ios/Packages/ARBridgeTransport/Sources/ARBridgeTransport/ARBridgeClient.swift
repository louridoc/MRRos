import Foundation

/// Errors from the `ar_bridge` HTTP surface. See `docs/protocols/ar_bridge_http.md`.
public enum ARBridgeError: Error, Equatable, Sendable {
    case invalidURI(String)
    case notFound(String)
    case unsupportedFormat(String)
    case notImplemented(String)
    case serverError(status: Int, message: String)
    case transport(String)
    case missingSHA256Header
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
        guard var components = URLComponents(url: baseURL, resolvingAgainstBaseURL: false) else {
            throw ARBridgeError.transport("invalid base URL \(baseURL)")
        }
        // Absolute path, not joined onto whatever `baseURL.path` is: `NSString.appendingPathComponent`
        // on an empty base (baseURL has no path, e.g. "http://host:8765") omits the leading "/",
        // which makes `URLComponents.url` return nil for a URL with an authority component.
        components.path = components.path.isEmpty ? "/v0/mesh" : components.path + "/v0/mesh"
        components.queryItems = [URLQueryItem(name: "uri", value: uri)]
        guard let url = components.url else {
            throw ARBridgeError.invalidURI(uri)
        }

        let response: HTTPResponse
        do {
            response = try await transport.get(url)
        } catch let e as ARBridgeError {
            throw e
        } catch {
            log
                .error(
                    "mesh fetch transport error for \(uri, privacy: .public): \(String(describing: error), privacy: .public)"
                )
            throw ARBridgeError.transport(String(describing: error))
        }

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

    /// `GET /health`.
    public func health() async throws -> ARBridgeHealth {
        let url = baseURL.appendingPathComponent("health")
        let response = try await transport.get(url)
        guard response.statusCode == 200 else {
            throw ARBridgeError.serverError(status: response.statusCode, message: bodyText(response))
        }
        return try JSONDecoder().decode(ARBridgeHealth.self, from: response.data)
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
