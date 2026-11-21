import Foundation

/// Scripted HTTP transport for tests and previews: map a URL (matched by substring) to a
/// canned response, or a thrown error.
public actor MockHTTPTransport: HTTPTransport {
    public struct Unscripted: Error {
        public let url: URL
    }

    private var responsesBySubstring: [(match: String, response: HTTPResponse)] = []
    private var errorsBySubstring: [(match: String, error: Error)] = []
    public private(set) var requestedURLs: [URL] = []
    public private(set) var postedBodies: [Data] = []

    public init() {}

    public func respond(whenURLContains match: String, with response: HTTPResponse) {
        responsesBySubstring.append((match, response))
    }

    public func fail(whenURLContains match: String, with error: Error) {
        errorsBySubstring.append((match, error))
    }

    public func get(_ url: URL) async throws -> HTTPResponse {
        try respond(to: url)
    }

    public private(set) var deletedURLs: [URL] = []

    public func delete(_ url: URL) async throws -> HTTPResponse {
        deletedURLs.append(url)
        return try respond(to: url)
    }

    /// (url, body) per PUT, in order — scene pushes must send points before the manifest.
    public private(set) var puts: [(url: URL, body: Data)] = []

    public func put(_ url: URL, body: Data) async throws -> HTTPResponse {
        puts.append((url, body))
        return try respond(to: url)
    }

    public func post(_ url: URL, body: Data) async throws -> HTTPResponse {
        postedBodies.append(body)
        return try respond(to: url)
    }

    private func respond(to url: URL) throws -> HTTPResponse {
        requestedURLs.append(url)
        let s = url.absoluteString
        if let hit = errorsBySubstring.first(where: { s.contains($0.match) }) {
            throw hit.error
        }
        if let hit = responsesBySubstring.first(where: { s.contains($0.match) }) {
            return hit.response
        }
        throw Unscripted(url: url)
    }
}
