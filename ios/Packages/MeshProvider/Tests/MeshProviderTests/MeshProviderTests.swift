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
