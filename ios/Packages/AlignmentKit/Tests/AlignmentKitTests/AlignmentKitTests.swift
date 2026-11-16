import Testing
@testable import AlignmentKit

@Suite struct AlignmentKitTests {
    @Test func packageLinks() {
        #expect(AlignmentKitInfo.name == "AlignmentKit")
    }
}
