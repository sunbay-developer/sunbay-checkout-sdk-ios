import XCTest

@testable import SunbayCheckout

final class CardOnFileOptionsTests: XCTestCase {
    func test_defaults() {
        let options = CardOnFileOptions()
        XCTAssertTrue(options.isEnabled)
        XCTAssertFalse(options.saveByDefault)
    }

    func test_configurationDefaultsToDefaultOptions() {
        XCTAssertEqual(CheckoutConfiguration().cardOnFile, CardOnFileOptions())
    }
}
