import XCTest
@testable import SunbayCheckout

final class PackageSmokeTests: XCTestCase {
    func test_version_isNonEmptySemver() {
        XCTAssertFalse(sunbayCheckoutVersion.isEmpty)
        XCTAssertEqual(sunbayCheckoutVersion.split(separator: ".").count, 3)
    }
}
