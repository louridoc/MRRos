import Testing
@testable import LiDARScan

@Suite struct LiDARScanTests {
    @Test func packageLinks() {
        #expect(LiDARScanInfo.name == "LiDARScan")
    }
}
