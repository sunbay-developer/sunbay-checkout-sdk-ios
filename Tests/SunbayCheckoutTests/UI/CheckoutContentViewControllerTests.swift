#if canImport(UIKit)
    import UIKit
    import XCTest

    @testable import SunbayCheckout

    /// Behavior tests for `CheckoutContentViewController` (spec §3.1–§3.3, Task 8).
    ///
    /// UIKit is iOS-only; on the macOS host (`swift test`) this whole file is excluded by
    /// `#if canImport(UIKit)` and is vacuous. The real RED/GREEN requires building against the iOS
    /// Simulator SDK. The suite drives the content VC through a `MockContentDelegate` and asserts the
    /// delegate contract: a confirm tap emits `.confirmNewCard` + `didChangeProcessing(true)`; applying
    /// a `.succeeded` outcome finishes with that outcome after the success animation; applying a
    /// `.failed` outcome keeps the sheet editable and reports `.failed`.
    @MainActor
    final class CheckoutContentViewControllerTests: XCTestCase {
        // MARK: - Helpers

        /// A trivial in-memory address-metadata service (simple mode never consults it, but the init
        /// requires one and full mode would).
        private struct MockAddressService: AddressMetadataService {
            func countries(locale: String?) async throws -> AddressCountryList {
                AddressCountryList(countries: [AddressCountry(code: "US", name: "United States")], detectedCountry: "US")
            }

            func countryConfig(countryCode: String, locale: String?) async throws -> AddressCountryConfig {
                AddressCountryConfig(
                    code: countryCode,
                    fields: [.country: AddressFieldConfig(
                        type: .country, required: true, pattern: nil, label: "Country", placeholder: "Country")],
                    layout: [[.country]],
                    subdivisions: []
                )
            }
        }

        /// Records the delegate callbacks so tests can assert the emitted actions / states.
        private final class MockContentDelegate: CheckoutContentDelegate {
            var lastRequestedAction: PaymentSheet.UserAction?
            var didChangeProcessingTrue = false
            var finishedOutcome: CheckoutOutcome?
            var lastState: CheckoutPresentationState?
            var canceled = false

            func content(_ content: CheckoutContentViewController, didRequest action: PaymentSheet.UserAction) {
                lastRequestedAction = action
            }

            func contentDidRequestCancel(_ content: CheckoutContentViewController) {
                canceled = true
            }

            func content(_ content: CheckoutContentViewController, didFinishWith outcome: CheckoutOutcome) {
                finishedOutcome = outcome
            }

            func content(_ content: CheckoutContentViewController, didChangeProcessing isProcessing: Bool) {
                if isProcessing { didChangeProcessingTrue = true }
            }

            func content(_ content: CheckoutContentViewController, didUpdateContentHeight height: CGFloat) {}

            func content(_ content: CheckoutContentViewController, didChangeState state: CheckoutPresentationState) {
                lastState = state
            }
        }

        private func makeSession(methods: Set<PaymentMethodKind> = [.card]) -> CheckoutSession {
            CheckoutSession(
                id: "sess_1",
                amount: Amount(minorUnits: 1999, currencyCode: "USD"),
                merchantName: "Demo Merchant",
                methods: methods,
                expiresAt: Date().addingTimeInterval(600),
                rsaPublicKey: nil,
                cofEnabled: false
            )
        }

        private func makeVC(savedCards: [SavedCard]) -> CheckoutContentViewController {
            CheckoutContentViewController(
                session: makeSession(),
                savedCards: savedCards,
                appearance: .resolve(.default),
                localize: { $0 },
                billingMode: .simple,
                shippingMode: .simple,
                addressService: MockAddressService()
            )
        }

        // MARK: - Tests

        func test_tapPayWithCompleteCardRequestsConfirmNewCard() {
            let vc = makeVC(savedCards: [])
            vc.loadViewIfNeeded()
            vc.fillCardForTest()
            let delegate = MockContentDelegate()
            vc.delegate = delegate

            vc.simulateTapPay()

            guard case .confirmNewCard = delegate.lastRequestedAction else {
                return XCTFail("Expected .confirmNewCard, got \(String(describing: delegate.lastRequestedAction))")
            }
            XCTAssertTrue(delegate.didChangeProcessingTrue)
            XCTAssertEqual(delegate.lastState, .processing)
        }

        func test_applySuccessFinishesWithOutcome() {
            let vc = makeVC(savedCards: [])
            vc.loadViewIfNeeded()
            vc.fillCardForTest()
            let delegate = MockContentDelegate()
            vc.delegate = delegate

            vc.simulateTapPay()
            vc.applyOutcome(.succeeded(txnId: "t"))

            // The success path waits out minimumFlightTime + successDisplayDuration before finishing.
            // Spin the main run loop (staying on the main actor) until the delegate finishes.
            let deadline = Date().addingTimeInterval(5.0)
            while delegate.finishedOutcome == nil, Date() < deadline {
                RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.02))
            }

            XCTAssertEqual(delegate.finishedOutcome, .succeeded(txnId: "t"))
            XCTAssertEqual(delegate.lastState, .succeeded)
        }

        func test_applyFailedStaysEditableAndReportsFailedState() {
            let vc = makeVC(savedCards: [])
            vc.loadViewIfNeeded()
            vc.fillCardForTest()
            let delegate = MockContentDelegate()
            vc.delegate = delegate

            vc.simulateTapPay()
            vc.applyOutcome(.failed(txnId: nil, error: CheckoutErrors.paymentFailed()))

            // The failed path waits out minimumFlightTime before applying the terminal UI.
            let deadline = Date().addingTimeInterval(3.0)
            while delegate.lastState != .failed, Date() < deadline {
                RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.02))
            }

            XCTAssertEqual(delegate.lastState, .failed)
            // The sheet stays open and re-editable: the card form is interactive again. (The machine's
            // own `state` stays `.failed(reason:)` until the next edit/retry; re-editability is that the
            // inputs are re-enabled, per spec §3.2.)
            XCTAssertTrue(vc.isCardFormInteractiveForTest, "Inputs should be re-enabled after a failure.")
        }
    }
#endif
