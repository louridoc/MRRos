import Testing
@testable import MeshProvider

@Suite struct MeshProviderTests {
    @Test func packageLinks() {
        #expect(MeshProviderInfo.name == "MeshProvider")
    }
}
