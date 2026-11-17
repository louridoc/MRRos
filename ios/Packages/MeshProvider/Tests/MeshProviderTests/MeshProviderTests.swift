import ARBridgeTransport
import Foundation
@testable import MeshProvider
import Testing

struct MeshKeyTests {
    @Test func parsesPackageURIs() {
        let k = MeshKey(uri: "package://ur_description/meshes/ur30/visual/forearm.dae")
        #expect(k == MeshKey(package: "ur_description", path: "meshes/ur30/visual/forearm.dae"))
        #expect(k?.bundledRelativePath == "ur_description/meshes/ur30/visual/forearm.usdz")
        #expect(k?.uri == "package://ur_description/meshes/ur30/visual/forearm.dae")
    }

    @Test func rejectsOtherSchemesAndTraversal() {
        #expect(MeshKey(uri: "file:///tmp/x.dae") == nil)
        #expect(MeshKey(uri: "package://onlypackage") == nil)
        #expect(MeshKey(uri: "package:///nopkg/x.dae") == nil)
        #expect(MeshKey(uri: "package://pkg/../../etc/passwd") == nil)
    }
}

struct DirectorySourceTests {
    private func makeTree() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("meshsrc-\(UUID().uuidString)")
        let file = root.appendingPathComponent("pkg/meshes/a.usdz")
        try FileManager.default.createDirectory(
            at: file.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data("usdz".utf8).write(to: file)
        let manifest = """
        {"version":1,"generated":"now","robots":["x"],"entries":[
          {"uri":"package://pkg/meshes/a.dae","file":"pkg/meshes/a.usdz","sha256":"00","bytes":4,"tris":1,
           "bbox":[0,0,0,1,1,1],"source":"test"}]}
        """
        try Data(manifest.utf8).write(to: root.appendingPathComponent("meshes.json"))
        return root
    }

    @Test func resolvesThroughManifestAndFallsBackToPathConvention() async throws {
        let root = try makeTree()
        let src = DirectoryMeshSource(name: "t", root: root)
        #expect(src.manifest?.entries.count == 1)
        let viaManifest = try await src.url(for: #require(MeshKey(uri: "package://pkg/meshes/a.dae")))
        #expect(viaManifest?.lastPathComponent == "a.usdz")

        // not in manifest but present on disk under the conventional path
        let extra = root.appendingPathComponent("pkg/meshes/b.usdz")
        try Data("x".utf8).write(to: extra)
        let viaPath = try await src.url(for: #require(MeshKey(uri: "package://pkg/meshes/b.stl")))
        #expect(viaPath?.lastPathComponent == "b.usdz")

        #expect(try await src.url(for: #require(MeshKey(uri: "package://pkg/meshes/missing.dae"))) == nil)
    }

    @Test func fallsBackToObjConventionWhenNoManifestAndNoUsdz() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("meshsrc-\(UUID().uuidString)")
        let file = root.appendingPathComponent("ur_description/meshes/ur16e/visual/base.obj")
        try FileManager.default.createDirectory(
            at: file.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        try Data("v 0 0 0".utf8).write(to: file)

        let src = DirectoryMeshSource(name: "cache", root: root) // no meshes.json here
        #expect(src.manifest == nil)
        let key = try #require(MeshKey(uri: "package://ur_description/meshes/ur16e/visual/base.dae"))
        let found = try await src.url(for: key)
        #expect(found?.lastPathComponent == "base.obj")
    }

    @Test func missingManifestIsAnEmptyTierNotAnError() async throws {
        let src = DirectoryMeshSource(name: "empty", root: URL(fileURLWithPath: "/nonexistent/\(UUID())"))
        #expect(src.manifest == nil)
        #expect(try await src.url(for: #require(MeshKey(uri: "package://p/a.dae"))) == nil)
    }

    @Test func providerTriesTiersInOrderAndMemoises() async throws {
        struct Counting: MeshSource {
            let name: String
            let hits: Set<String>
            let counter: Counter
            func url(for key: MeshKey) async throws -> URL? {
                await counter.bump()
                return hits.contains(key.uri) ? URL(fileURLWithPath: "/\(name)/\(key.path)") : nil
            }
        }
        actor Counter { var n = 0; func bump() {
            n += 1
        } }
        let c1 = Counter(), c2 = Counter()
        let p = MeshProvider(sources: [
            Counting(name: "one", hits: ["package://p/a.dae"], counter: c1),
            Counting(name: "two", hits: ["package://p/b.dae"], counter: c2),
        ])
        #expect(try await p.resolve("package://p/a.dae").path == "/one/a.dae")
        #expect(try await p.resolve("package://p/b.dae").path == "/two/b.dae")
        _ = try await p.resolve("package://p/a.dae") // memoised
        #expect(await c1.n == 2)
        #expect(await c2.n == 1)
        await #expect(throws: try MeshProviderError.notFound(#require(MeshKey(uri: "package://p/zzz.dae")))) {
            _ = try await p.resolve("package://p/zzz.dae")
        }
        await #expect(throws: MeshProviderError.invalidURI("http://x")) {
            _ = try await p.resolve("http://x")
        }
    }
}

struct RemoteMeshSourceTests {
    private func makeClient(mock: MockHTTPTransport) -> ARBridgeClient {
        ARBridgeClient(baseURL: URL(string: "http://mock:8765")!, transport: mock)
    }

    @Test func fetchesConvertsCachesAndReturnsTheCachedFile() async throws {
        let mock = MockHTTPTransport()
        await mock.respond(
            whenURLContains: "/v0/mesh",
            with: HTTPResponse(
                statusCode: 200, data: Data("v 0 0 0\nf 1 1 1".utf8),
                headers: ["X-Mesh-SHA256": "abc123"]
            )
        )
        let cacheRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("remotecache-\(UUID().uuidString)")
        let source = RemoteMeshSource(client: makeClient(mock: mock), cacheRoot: cacheRoot)
        let key = try #require(MeshKey(uri: "package://ur_description/meshes/ur16e/visual/base.dae"))

        let url = try await source.url(for: key)
        #expect(url?.lastPathComponent == "base.obj")
        #expect(try #require(url).path.contains("ur_description/meshes/ur16e/visual"))
        #expect(try Data(contentsOf: #require(url)) == Data("v 0 0 0\nf 1 1 1".utf8))

        // A plain DirectoryMeshSource over the same root now finds it too (tier 2 on next launch).
        let cacheTier = DirectoryMeshSource(name: "cache", root: cacheRoot)
        #expect(try await cacheTier.url(for: key) == url)
    }

    @Test func propagatesRichErrorsRatherThanSwallowingToNil() async throws {
        let mock = MockHTTPTransport()
        await mock.respond(
            whenURLContains: "/v0/mesh",
            with: HTTPResponse(statusCode: 404, data: Data("gone".utf8), headers: [:])
        )
        let source = RemoteMeshSource(
            client: makeClient(mock: mock),
            cacheRoot: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        )
        let key = try #require(MeshKey(uri: "package://pkg/missing.dae"))
        await #expect(throws: ARBridgeError.notFound("gone")) {
            _ = try await source.url(for: key)
        }
    }

    @Test func standardWithoutArBridgeNeverTriesTheNetwork() async throws {
        // No client given: resolve() must fail with the generic "no tier had it" error, not
        // anything network-shaped — proving the remote tier is genuinely absent, not just failing.
        let withoutClient = MeshProvider.standard()
        let key = try #require(MeshKey(uri: "package://nowhere/x.dae"))
        await #expect(throws: MeshProviderError.notFound(key)) {
            _ = try await withoutClient.resolve("package://nowhere/x.dae")
        }
    }

    @Test func standardWithArBridgeTriesTheRemoteTierOnMiss() async throws {
        let mock = MockHTTPTransport()
        await mock.respond(
            whenURLContains: "/v0/mesh",
            with: HTTPResponse(statusCode: 404, data: Data("gone".utf8), headers: [:])
        )
        let withClient = MeshProvider.standard(arBridge: makeClient(mock: mock))
        // Bundled and cache tiers miss (nothing on disk for this made-up key), so this must
        // reach the remote tier and surface ITS error — not the generic "no tier had it" one —
        // proving the remote tier was actually appended and consulted.
        await #expect(throws: ARBridgeError.notFound("gone")) {
            _ = try await withClient.resolve("package://nowhere/x.dae")
        }
    }
}

/// Dev-machine check: the committed bundle covers every visual mesh the fixture robots reference.
struct BundleCoverageTests {
    static let repoRoot = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent().deletingLastPathComponent()
    static let meshesDir = repoRoot.appendingPathComponent("ios/MRRos/Meshes")
    static let fixturesDir = repoRoot.appendingPathComponent("ios/Packages/URDFKit/Tests/Fixtures")
    static var available: Bool {
        FileManager.default.fileExists(atPath: meshesDir.appendingPathComponent("meshes.json").path)
    }

    @Test(.enabled(if: available))
    func bundledMeshesCoverAllFixtureVisuals() async throws {
        let src = DirectoryMeshSource(name: "bundled", root: Self.meshesDir)
        let manifest = try #require(src.manifest)
        var missing: [String] = []
        var checked = 0
        for robot in manifest.robots {
            let urdf = try String(
                contentsOf: Self.fixturesDir.appendingPathComponent("\(robot)/robot.urdf"),
                encoding: .utf8
            )
            for block in urdf.components(separatedBy: "<visual>").dropFirst() {
                let visual = block.components(separatedBy: "</visual>")[0]
                guard let r = visual.range(of: #"package://[^"]+"#, options: .regularExpression)
                else { continue }
                let uri = String(visual[r])
                checked += 1
                if try await src.url(for: #require(MeshKey(uri: uri))) == nil {
                    missing.append(uri)
                }
            }
        }
        #expect(checked >= 30, "expected ≥30 visual meshes across \(manifest.robots)")
        #expect(missing.isEmpty, "missing: \(missing)")
        for e in manifest.entries {
            #expect(e.bbox.count == 6 && e.tris > 0 && e.bytes > 0, "\(e.uri)")
            let extent = zip(e.bbox.prefix(3), e.bbox.suffix(3)).map { $1 - $0 }.max() ?? 0
            #expect(extent > 0.02 && extent < 3, "\(e.uri): extent \(extent) m looks like a unit problem")
        }
    }
}
