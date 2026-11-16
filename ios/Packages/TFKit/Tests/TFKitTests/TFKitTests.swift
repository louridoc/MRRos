import Testing
@testable import TFKit

@Suite struct TFKitTests {
    @Test func packageLinks() {
        #expect(TFKitInfo.name == "TFKit")
    }
}
