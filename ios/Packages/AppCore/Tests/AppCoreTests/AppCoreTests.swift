import Testing
@testable import AppCore

@Suite struct AppCoreTests {
    @Test func packageLinks() {
        #expect(AppCoreInfo.name == "AppCore")
    }
}
