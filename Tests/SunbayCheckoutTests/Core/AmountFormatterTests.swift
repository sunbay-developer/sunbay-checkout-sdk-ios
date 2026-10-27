import XCTest
@testable import SunbayCheckout

final class AmountFormatterTests: XCTestCase {
    func test_usd_formatsWithTwoFractionDigits() {
        let s = AmountFormatter().string(from: Amount(minorUnits: 999, currencyCode: "USD"),
                                         locale: Locale(identifier: "en_US"))
        XCTAssertEqual(s, "$9.99")
    }

    func test_jpy_formatsWithZeroFractionDigits() {
        let s = AmountFormatter().string(from: Amount(minorUnits: 1000, currencyCode: "JPY"),
                                         locale: Locale(identifier: "ja_JP"))
        XCTAssertTrue(s.contains("1,000")) // no decimal scaling for JPY
    }

    func test_zeroAmount() {
        let s = AmountFormatter().string(from: Amount(minorUnits: 0, currencyCode: "USD"),
                                         locale: Locale(identifier: "en_US"))
        XCTAssertEqual(s, "$0.00")
    }
}
