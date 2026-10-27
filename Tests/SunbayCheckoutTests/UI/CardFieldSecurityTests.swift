#if canImport(UIKit)
    import UIKit
    import XCTest

    @testable import SunbayCheckout

    /// CardField security spec unit test (security-and-pci.md §3 item 2 / §3.1, product-spec §5.3.1).
    ///
    /// UIKit is iOS-only. When built on the macOS host for `swift test`, this entire file is excluded by
    /// `#if canImport(UIKit)` — it neither compiles nor runs; the real RED/GREEN requires building against
    /// the iOS Simulator SDK (see the task report). On-device verification is covered by the example App (Task 13).
    final class CardFieldSecurityTests: XCTestCase {
        func test_cardFieldSecurity_disablesKeyboardLearning_andCVVHasNoContentType() {
            let pan = UITextField()
            let exp = UITextField()
            let cvv = UITextField()
            CardFieldSecurity.apply(toPAN: pan, expiry: exp, cvv: cvv)
            for f in [pan, exp, cvv] {
                XCTAssertEqual(f.autocorrectionType, .no)
                XCTAssertEqual(f.spellCheckingType, .no)
                XCTAssertEqual(f.smartDashesType, .no)
            }
            XCTAssertEqual(pan.textContentType, .creditCardNumber)
            XCTAssertNil(cvv.textContentType)  // CVV must never go into autofill
            XCTAssertEqual(pan.keyboardType, .asciiCapableNumberPad)
        }
    }
#endif
