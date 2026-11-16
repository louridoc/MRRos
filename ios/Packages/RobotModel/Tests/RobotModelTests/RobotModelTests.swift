import Testing
@testable import RobotModel

@Suite struct RobotModelTests {
    @Test func packageLinks() {
        #expect(RobotModelInfo.name == "RobotModel")
    }
}
