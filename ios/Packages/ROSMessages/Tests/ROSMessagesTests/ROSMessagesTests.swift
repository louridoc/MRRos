import Testing
@testable import ROSMessages

@Suite struct ROSMessagesTests {
    @Test func packageLinks() {
        #expect(ROSMessagesInfo.name == "ROSMessages")
    }
}
