import Testing
@testable import ROSBridgeClient

@Suite struct ROSBridgeClientTests {
    @Test func packageLinks() {
        #expect(ROSBridgeClientInfo.name == "ROSBridgeClient")
    }
}
