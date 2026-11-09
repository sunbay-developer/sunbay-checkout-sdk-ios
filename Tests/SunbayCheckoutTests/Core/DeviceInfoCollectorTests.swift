import XCTest
@testable import SunbayCheckout

final class DeviceInfoCollectorTests: XCTestCase {
    func testCollectWithScreen() {
        let info = DeviceInfoCollector.collect(screen: (width: 390, height: 844, scale: 3))
        XCTAssertEqual(info.screenWidth, "1170")
        XCTAssertEqual(info.screenHeight, "2532")
        XCTAssertEqual(info.deviceResolution, "1170x2532")
        XCTAssertEqual(info.deviceOs, "iOS")
        XCTAssertEqual(info.deviceType, "mobile")
        XCTAssertFalse(info.language?.isEmpty ?? true)
        XCTAssertEqual(info.timeZoneOffset, String(-TimeZone.current.secondsFromGMT() / 60))
        XCTAssertFalse(info.deviceModel?.isEmpty ?? true)
    }

    func testCollectWithoutScreenOmitsMetrics() {
        let info = DeviceInfoCollector.collect(screen: nil)
        XCTAssertNil(info.screenWidth)
        XCTAssertNil(info.screenHeight)
        XCTAssertNil(info.deviceResolution)
    }
}
