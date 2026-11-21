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

    // MARK: - uploadCloud

    @Test func uploadCloudSendsBodyAndQueryThenDecodesTheResult() async throws {
        let mock = MockHTTPTransport()
        let json = """
        {"points": 430, "file": "/x/myscan.pcd", "topic": "/mrros/static_cloud"}
        """
        await mock.respond(
            whenURLContains: "/v0/cloud",
            with: HTTPResponse(statusCode: 200, data: Data(json.utf8), headers: [:])
        )
        let client = ARBridgeClient(baseURL: baseURL, transport: mock)
        let plyBytes = Data("fake ply bytes".utf8)
        let result = try await client.uploadCloud(plyBytes, frameId: "map", name: "myscan", mode: .append)
        #expect(result == CloudUploadResult(points: 430, file: "/x/myscan.pcd", topic: "/mrros/static_cloud"))

        #expect(await mock.postedBodies == [plyBytes])
        let url = try #require(await mock.requestedURLs.first)
        let q = try #require(URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems)
        #expect(q.contains(URLQueryItem(name: "frame_id", value: "map")))
        #expect(q.contains(URLQueryItem(name: "mode", value: "append")))
        #expect(q.contains(URLQueryItem(name: "name", value: "myscan")))
    }

    @Test func uploadCloudDefaultsToReplaceModeAndOmitsNameWhenNil() async throws {
        let mock = MockHTTPTransport()
        await mock.respond(
            whenURLContains: "/v0/cloud",
            with: HTTPResponse(
                statusCode: 200,
                data: Data(#"{"points": 1, "file": "/x.pcd", "topic": "/t"}"#.utf8), headers: [:]
            )
        )
        let client = ARBridgeClient(baseURL: baseURL, transport: mock)
        _ = try await client.uploadCloud(Data(), frameId: "map")
        let url = try #require(await mock.requestedURLs.first)
        let q = try #require(URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems)
        #expect(q.contains(URLQueryItem(name: "mode", value: "replace")))
        #expect(!q.contains { $0.name == "name" })
    }

    @Test(arguments: [
        (400, ARBridgeError.badRequest("bad")),
        (413, ARBridgeError.payloadTooLarge("bad")),
        (501, ARBridgeError.notImplemented("bad")),
    ])
    func uploadCloudMapsStatusCodesToTypedErrors(status: Int, expected: ARBridgeError) async {
        let mock = MockHTTPTransport()
        await mock.respond(
            whenURLContains: "/v0/cloud",
            with: HTTPResponse(statusCode: status, data: Data("bad".utf8), headers: [:])
        )
        let client = ARBridgeClient(baseURL: baseURL, transport: mock)
        await #expect(throws: expected) {
            _ = try await client.uploadCloud(Data(), frameId: "map")
        }
    }

    @Test func uploadCloudMalformedJSONBodyIsAMalformedResponseError() async {
        let mock = MockHTTPTransport()
        await mock.respond(
            whenURLContains: "/v0/cloud",
            with: HTTPResponse(statusCode: 200, data: Data("not json".utf8), headers: [:])
        )
        let client = ARBridgeClient(baseURL: baseURL, transport: mock)
        await #expect(throws: ARBridgeError.self) {
            _ = try await client.uploadCloud(Data(), frameId: "map")
        }
    }

    // MARK: - clearCloud

    @Test func clearCloudSendsDeleteWithName() async throws {
        let mock = MockHTTPTransport()
        await mock.respond(
            whenURLContains: "/v0/cloud",
            with: HTTPResponse(statusCode: 200, data: Data(#"{"cleared":"live_scan"}"#.utf8), headers: [:])
        )
        let client = ARBridgeClient(baseURL: baseURL, transport: mock)
        try await client.clearCloud(name: "live_scan")
        let url = try #require(await mock.deletedURLs.first)
        #expect(url.path == "/v0/cloud")
        #expect(url.query == "name=live_scan")
    }

    @Test func clearCloudOnOlderBridgeIsNotImplemented() async {
        let mock = MockHTTPTransport()
        await mock.respond(
            whenURLContains: "/v0/cloud",
            with: HTTPResponse(statusCode: 501, data: Data("nope".utf8), headers: [:])
        )
        let client = ARBridgeClient(baseURL: baseURL, transport: mock)
        await #expect(throws: ARBridgeError.notImplemented("nope")) {
            try await client.clearCloud()
        }
    }

    @Test func listScenesDecodesRows() async throws {
        let mock = MockHTTPTransport()
        let body = #"{"scenes": [{"id": "bench_1", "manifest": {"name": "Bench", "createdAt": "2026-11-21T10:00:00Z", "pointCount": 12, "robotName": "ur10e", "extra": 1}}]}"#
        await mock.respond(whenURLContains: "/v0/scenes", with: HTTPResponse(statusCode: 200, data: Data(body.utf8), headers: [:]))
        let rows = try await ARBridgeClient(baseURL: baseURL, transport: mock).listScenes()
        #expect(rows.map(\.id) == ["bench_1"])
        #expect(rows.first?.manifest.pointCount == 12)
    }

    @Test func putSceneFileSendsBodyToTheFilePath() async throws {
        let mock = MockHTTPTransport()
        await mock.respond(whenURLContains: "/v0/scenes/", with: HTTPResponse(statusCode: 200, data: Data("{}".utf8), headers: [:]))
        try await ARBridgeClient(baseURL: baseURL, transport: mock).putSceneFile(id: "bench_1", file: "points.ply", data: Data([1, 2]))
        let puts = await mock.puts
        #expect(puts.first?.url.path == "/v0/scenes/bench_1/points.ply")
        #expect(puts.first?.body == Data([1, 2]))
    }

    @Test func unsafeSceneIDsNeverReachTheNetwork() async {
        let mock = MockHTTPTransport()
        let client = ARBridgeClient(baseURL: baseURL, transport: mock)
        for bad in ["../x", "a/b", ".hidden", "", "a b"] {
            await #expect(throws: ARBridgeError.self) { try await client.deleteScene(id: bad) }
        }
        #expect(await mock.requestedURLs.isEmpty)
    }

    @Test func missingSceneIsNotFound() async {
        let mock = MockHTTPTransport()
        await mock.respond(whenURLContains: "/v0/scenes/", with: HTTPResponse(statusCode: 404, data: Data("gone".utf8), headers: [:]))
        await #expect(throws: ARBridgeError.notFound("gone")) {
            try await ARBridgeClient(baseURL: baseURL, transport: mock).sceneFile(id: "x", file: "scene.json")
        }
    }

    @Test func uploadSceneMeshPostsToTheMeshEndpoint() async throws {
        let mock = MockHTTPTransport()
        let body = #"{"triangles": 12, "vertices": 8, "object_id": "mrros_scan_mesh", "applied": true}"#
        await mock.respond(whenURLContains: "/v0/scene_mesh", with: HTTPResponse(statusCode: 200, data: Data(body.utf8), headers: [:]))
        let result = try await ARBridgeClient(baseURL: baseURL, transport: mock).uploadSceneMesh(Data([1]), frameId: "base_link")
        #expect(result == SceneMeshResult(triangles: 12, vertices: 8, objectId: "mrros_scan_mesh", applied: true))
        #expect(await mock.requestedURLs.first?.query == "frame_id=base_link")
        #expect(await mock.postedBodies == [Data([1])])
    }
}
