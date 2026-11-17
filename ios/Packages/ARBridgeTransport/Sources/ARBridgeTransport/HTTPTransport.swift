import Foundation

/// A raw HTTP GET, abstracted so tests can inject a scripted transport instead of hitting the
/// network (same pattern as `ROSBridgeClient.WebSocketTransport`).
public protocol HTTPTransport: Sendable {
    func get(_ url: URL) async throws -> HTTPResponse
}

public struct HTTPResponse: Sendable, Equatable {
    public let statusCode: Int
    public let data: Data
    public let headers: [String: String]

    public init(statusCode: Int, data: Data, headers: [String: String]) {
        self.statusCode = statusCode
        self.data = data
        self.headers = headers
    }

    /// Case-insensitive header lookup (HTTP header names are case-insensitive; URLSession
    /// normalizes them inconsistently across platforms, so don't rely on exact case).
    public func header(_ name: String) -> String? {
        headers.first { $0.key.caseInsensitiveCompare(name) == .orderedSame }?.value
    }
}

/// Production transport over `URLSession`.
public struct URLSessionHTTPTransport: HTTPTransport {
    private let session: URLSession

    public init(session: URLSession = .shared) {
        self.session = session
    }

    public func get(_ url: URL) async throws -> HTTPResponse {
        let (data, response) = try await session.data(from: url)
        guard let http = response as? HTTPURLResponse else {
            throw ARBridgeError.transport("non-HTTP response from \(url)")
        }
        var headers: [String: String] = [:]
        for (key, value) in http.allHeaderFields {
            if let k = key as? String, let v = value as? String {
                headers[k] = v
            }
        }
        return HTTPResponse(statusCode: http.statusCode, data: data, headers: headers)
    }
}
