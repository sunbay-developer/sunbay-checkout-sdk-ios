#if canImport(UIKit)
    import UIKit
    import XCTest

    @testable import SunbayCheckout

    /// Keyboard dismissal behavior of the payment sheet.
    ///
    /// Regression coverage for: the keyboard staying up after tapping outside the fields, after
    /// leaving the new-card page via the back button, and number-pad fields having no way to dismiss
    /// (no Return key). iOS-only; vacuous on the macOS host.
    @MainActor
    final class KeyboardDismissalTests: XCTestCase {
        // MARK: - Helpers

        private struct StubAddressService: AddressMetadataService {
            func countries(locale: String?) async throws -> AddressCountryList {
                AddressCountryList(countries: [], detectedCountry: nil)
            }

            func countryConfig(countryCode: String, locale: String?) async throws -> AddressCountryConfig {
                AddressCountryConfig(code: countryCode, fields: [:], layout: [], subdivisions: [])
            }
        }

        /// Hosts a content VC on the new-card page inside a real window (first responder needs one).
        private func makeHostedNewCardVC() -> (CheckoutContentViewController, UIWindow) {
            let session = CheckoutSession(
                id: "s", amount: Amount(minorUnits: 100, currencyCode: "USD"), merchantName: "m",
                methods: [.card], expiresAt: Date().addingTimeInterval(600), rsaPublicKey: nil,
                cofEnabled: false)
            let vc = CheckoutContentViewController(
                session: session, savedCards: [], appearance: .resolve(.default), localize: { $0 },
                localeCode: nil, billingMode: .simple, shippingMode: .simple,
                addressService: StubAddressService())
            let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 844))
            window.rootViewController = vc
            window.makeKeyAndVisible()
            vc.view.layoutIfNeeded()
            vc.openNewCardForTest()
            vc.view.layoutIfNeeded()
            return (vc, window)
        }

        private func textFields(in view: UIView) -> [UITextField] {
            var result: [UITextField] = []
            if let field = view as? UITextField { result.append(field) }
            for sub in view.subviews { result.append(contentsOf: textFields(in: sub)) }
            return result
        }

        private func firstResponder(in view: UIView) -> UIView? {
            if view.isFirstResponder { return view }
            for sub in view.subviews {
                if let found = firstResponder(in: sub) { return found }
            }
            return nil
        }

        /// Focuses the card-number field and asserts focus was actually obtained.
        private func focusCardNumber(in vc: CheckoutContentViewController) throws {
            let pan = try XCTUnwrap(
                textFields(in: vc.view).first { $0.textContentType == .creditCardNumber },
                "Card number field not found")
            XCTAssertTrue(pan.becomeFirstResponder(), "Precondition: card number field takes focus.")
            XCTAssertNotNil(firstResponder(in: vc.view), "Precondition: a field is first responder.")
        }

        // MARK: - Tests

        func test_backToHome_resignsFirstResponder() throws {
            let (vc, window) = makeHostedNewCardVC()
            defer { window.isHidden = true; window.rootViewController = nil }
            try focusCardNumber(in: vc)

            vc.tapBackForTest()

            XCTAssertNil(firstResponder(in: vc.view), "Leaving the new-card page must dismiss the keyboard.")
        }

        func test_backgroundTap_resignsFirstResponder() throws {
            let (vc, window) = makeHostedNewCardVC()
            defer { window.isHidden = true; window.rootViewController = nil }
            try focusCardNumber(in: vc)

            vc.simulateBackgroundTapForTest()

            XCTAssertNil(firstResponder(in: vc.view), "Tapping outside the fields must dismiss the keyboard.")
        }

        func test_numberPadFields_haveDoneAccessory() {
            let (vc, window) = makeHostedNewCardVC()
            defer { window.isHidden = true; window.rootViewController = nil }

            let padFields = textFields(in: vc.view).filter {
                $0.keyboardType == .asciiCapableNumberPad || $0.keyboardType == .numbersAndPunctuation
            }
            XCTAssertGreaterThanOrEqual(padFields.count, 4, "PAN, expiry, CVV and postal code use pad keyboards.")
            for field in padFields {
                XCTAssertNotNil(field.inputAccessoryView, "A pad keyboard has no Return key; it needs a Done bar.")
            }
        }

        func test_shouldHandleTap_ignoresTextInputsAndControls() {
            let plain = UIView()
            let field = UITextField()
            let inner = UIView()
            field.addSubview(inner)
            let button = UIButton(type: .system)

            XCTAssertTrue(KeyboardDismissal.shouldHandleTap(on: plain))
            XCTAssertTrue(KeyboardDismissal.shouldHandleTap(on: nil))
            XCTAssertFalse(KeyboardDismissal.shouldHandleTap(on: field), "Tapping a field must keep/move focus.")
            XCTAssertFalse(KeyboardDismissal.shouldHandleTap(on: inner), "A subview of a field counts as the field.")
            XCTAssertFalse(KeyboardDismissal.shouldHandleTap(on: button), "Controls handle their own taps.")
        }
    }
#endif
