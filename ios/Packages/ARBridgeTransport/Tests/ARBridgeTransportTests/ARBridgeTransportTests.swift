import Testing
@testable import ARBridgeTransport

@Suite struct ARBridgeTransportTests {
    @Test func packageLinks() {
        #expect(ARBridgeTransportInfo.name == "ARBridgeTransport")
    }
}
