import XCTest
@testable import SunbayCheckout

final class LocalizationHelperTests: XCTestCase {
    func test_returnsLocalizedValue_fromModuleBundle() {
        // "sunbay.sheet.pay" exists in en.lproj → "Pay"
        XCTAssertEqual(SunbayLocalizedString("sunbay.sheet.pay", "comment"), "Pay")
    }

    func test_missingKey_returnsKeyNotEmptyString() {
        XCTAssertEqual(SunbayLocalizedString("sunbay.nonexistent.key", "comment"), "sunbay.nonexistent.key")
    }
}
