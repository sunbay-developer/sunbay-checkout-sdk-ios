#if canImport(UIKit)
    import UIKit
    import XCTest

    @testable import SunbayCheckout

    /// Unit tests for `CardFormView`'s `cardInput` assembly (absorbed from the former `CardField`).
    ///
    /// UIKit is iOS-only. On the macOS host (`swift test`) this whole file is excluded by
    /// `#if canImport(UIKit)` and is vacuous; the real RED/GREEN requires building against the iOS
    /// Simulator SDK. The two cases mirror the former `CardField.cardInput` rules: `nil` when any of
    /// PAN / expiry / CVC is empty, and a populated `CardInput` (with the expiry split on `/`) when all
    /// three are filled.
    final class CardFormViewTests: XCTestCase {
        func test_cardInputNilWhenIncomplete() {
            let v = CardFormView(appearance: .resolve(.default), localize: { $0 })
            XCTAssertNil(v.cardInput)
        }

        func test_cardInputAssemblesWhenComplete() {
            let v = CardFormView(appearance: .resolve(.default), localize: { $0 })
            v.setFieldsForTest(pan: "4242424242424242", expiry: "08/99", cvv: "123")
            XCTAssertEqual(v.cardInput?.cardNumber, "4242424242424242")
            XCTAssertEqual(v.cardInput?.expiryMonth, "08")
            XCTAssertEqual(v.cardInput?.expiryYear, "2099")
        }
    }
#endif
