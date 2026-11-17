@testable import ARBridgeTransport
import Foundation
import Testing

private let baseURL = URL(string: "http://mock:8765")!

struct ARBridgeClientTests {
    @Test func fetchMeshSuccessReturnsDataAndSourceSHA() async throws {
        let mock = MockHTTPTransport()
        await mock.respond(
            whenURLContains: "/v0/mesh",
            with: HTTPResponse(
                statusCode: 200, data: Data("v 0 0 0\n".utf8),
                headers: ["X-Mesh-SHA256": "deadbeef", "Content-Type": "model/obj"]
            )
        )
        let client = ARBridgeClient(baseURL: baseURL, transport: mock)
        let mesh = try await client.fetchMesh(uri: "package://ur_description/meshes/ur16e/visual/base.dae")
        #expect(mesh.sourceSHA256 == "deadbeef")
        #expect(mesh.data == Data("v 0 0 0\n".utf8))

        let requested = await mock.requestedURLs
        #expect(requested.count == 1)
        #expect(requested[0].absoluteString.contains("uri=package://"))
        #expect(requested[0].path == "/v0/mesh")
    }

    @Test func fetchMeshMissingSHAHeaderIsAnError() async {
        let mock = MockHTTPTransport()
        await mock.respond(
            whenURLContains: "/v0/mesh",
            with: HTTPResponse(statusCode: 200, data: Data(), headers: [:])
        )
        let client = ARBridgeClient(baseURL: baseURL, transport: mock)
        await #expect(throws: ARBridgeError.missingSHA256Header) {
            _ = try await client.fetchMesh(uri: "package://pkg/a.dae")
        }
    }

    @Test(arguments: [
        (400, ARBridgeError.invalidURI("bad")),
        (404, ARBridgeError.notFound("bad")),
        (415, ARBridgeError.unsupportedFormat("bad")),
        (501, ARBridgeError.notImplemented("bad")),
    ])
    func fetchMeshMapsStatusCodesToTypedErrors(status: Int, expected: ARBridgeError) async {
        let mock = MockHTTPTransport()
        await mock.respond(
            whenURLContains: "/v0/mesh",
            with: HTTPResponse(statusCode: status, data: Data("bad".utf8), headers: [:])
        )
        let client = ARBridgeClient(baseURL: baseURL, transport: mock)
        await #expect(throws: expected) {
            _ = try await client.fetchMesh(uri: "package://pkg/a.dae")
        }
    }

    @Test func fetchMeshUnexpectedStatusIsServerError() async {
        let mock = MockHTTPTransport()
        await mock.respond(
            whenURLContains: "/v0/mesh",
            with: HTTPResponse(statusCode: 503, data: Data("down".utf8), headers: [:])
        )
        let client = ARBridgeClient(baseURL: baseURL, transport: mock)
        await #expect(throws: ARBridgeError.serverError(status: 503, message: "down")) {
            _ = try await client.fetchMesh(uri: "package://pkg/a.dae")
        }
    }

    @Test func transportFailureWrapsIntoTransportError() async {
        let mock = MockHTTPTransport()
        struct Boom: Error {}
        await mock.fail(whenURLContains: "/v0/mesh", with: Boom())
        let client = ARBridgeClient(baseURL: baseURL, transport: mock)
        await #expect(throws: ARBridgeError.self) {
            _ = try await client.fetchMesh(uri: "package://pkg/a.dae")
        }
    }

    @Test func healthDecodesSnakeCaseFields() async throws {
        let mock = MockHTTPTransport()
        let json = """
        {"ok":true,"node":"ar_bridge","protocol":0,"ros_distro":"jazzy"}
        """
        await mock.respond(
            whenURLContains: "/health",
            with: HTTPResponse(statusCode: 200, data: Data(json.utf8), headers: [:])
        )
        let client = ARBridgeClient(baseURL: baseURL, transport: mock)
        let health = try await client.health()
        #expect(health == ARBridgeHealth(ok: true, node: "ar_bridge", protocolVersion: 0, rosDistro: "jazzy"))
    }

    @Test func headerLookupIsCaseInsensitive() {
        let r = HTTPResponse(statusCode: 200, data: Data(), headers: ["x-mesh-sha256": "abc"])
        #expect(r.header("X-Mesh-SHA256") == "abc")
    }
}
