import Testing
@testable import URDFKit

@Suite struct URDFKitTests {
    @Test func packageLinks() {
        #expect(URDFKitInfo.name == "URDFKit")
    }
}
