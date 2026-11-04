#if canImport(UIKit)
    import UIKit
    import XCTest

    @testable import SunbayCheckout

    /// Retry-loop coverage for the rewired `PaymentSheet` (Task 9) plus the container's state bridge.
    ///
    /// ## Where the retry lives
    /// `runCheckout(seam:)` stays **single-shot** (one seam call → one confirm → one outcome), to
    /// preserve the existing `PaymentSheetTests`. The retry loop is implemented in the
    /// present/container layer: on a non-terminal outcome (`.failed` / `.pending` / `.unknown`) the
    /// content VC stays open and re-editable, and the next user confirm drives **another**
    /// `runCheckout` attempt. The present layer therefore loops `runCheckout` — one call per confirm.
    ///
    /// These tests exercise that exact mechanism at the `runCheckout` seam the present layer loops
    /// over: calling `runCheckout` twice (a first confirm whose submit fails, a second whose submit
    /// succeeds) models "failed round → user taps again → second confirm succeeds". This runs
    /// headlessly (no real UIKit presentation), identical to how `PaymentSheetTests` drives the seam.
    ///
    /// UIKit is iOS-only; on the macOS host this whole file is excluded by `#if canImport(UIKit)`. The
    /// real RED/GREEN requires building against the iOS Simulator SDK (see the task report).
    final class PaymentSheetRunCheckoutTests: XCTestCase {
        // MARK: - Assembly

        private func makeSession(id: String, cofEnabled: Bool) -> CheckoutSession {
            CheckoutSession(
                id: id,
                amount: Amount(minorUnits: 999, currencyCode: "USD"),
                merchantName: "Acme",
                methods: [.card, .savedCard],
                expiresAt: Date().addingTimeInterval(600),
                rsaPublicKey: nil,
                cofEnabled: cofEnabled
            )
        }

        /// Assembles a real `CheckoutController` with a mock backend; the submit sequence is scripted
        /// so the first confirm fails and the second succeeds.
        private func makeController(
            session: CheckoutSession,
            cards: [SavedCard],
            submit snapshots: [PaymentSnapshot]
        ) -> (CheckoutController, MockPaymentService, MockCofService) {
            let payment = MockPaymentService()
            payment.stubSession(session)
            payment.stubSubmit(snapshots)
            let cof = MockCofService()
            cof.stubCards(cards)
            let controller = CheckoutController(
                paymentService: payment,
                cofService: cof,
                credentials: CredentialStore(),
                actionHandler: StubActionHandler(result: .pending)
            )
            return (controller, payment, cof)
        }

        // MARK: - Retry loop

        /// A failed first confirm followed by a successful second confirm: two `runCheckout` attempts
        /// (what the present layer loops over) map to two submits, and the second returns success.
        func test_retryAfterFailedConfirmsAgain() async {
            let sessionId = "sess_retry_1"
            let session = makeSession(id: sessionId, cofEnabled: true)
            let card = SavedCard(id: "pm_1", brand: "visa", last4: "4242", expMonth: 12, expYear: 2030)
            let (controller, payment, _) = makeController(
                session: session,
                cards: [card],
                submit: [
                    PaymentSnapshot(sessionId: sessionId, status: .failed, txnId: "t1"),
                    PaymentSnapshot(sessionId: sessionId, status: .succeeded, txnId: "t2"),
                ]
            )

            let sheet = PaymentSheet(
                controller: controller,
                sessionId: sessionId,
                customerAccessSecret: "secret_abc"
            )

            // Round 1: confirm the saved card → submit scripted to fail.
            let first = await sheet.runCheckout { _ in .confirmSavedCard(paymentMethodId: "pm_1") }
            guard case .failed = first else {
                return XCTFail("expected .failed on the first attempt, got \(first)")
            }

            // Round 2 (the retry the present layer drives after the sheet stayed open): confirm again
            // → submit scripted to succeed.
            let second = await sheet.runCheckout { _ in .confirmSavedCard(paymentMethodId: "pm_1") }

            XCTAssertEqual(second, .succeeded(txnId: "t2"))
            // Each confirm reached the backend exactly once: no blind resubmit, one submit per attempt.
            XCTAssertEqual(payment.submitCallCount, 2)
        }

        /// The single-active guard holds across rounds: a confirm that is NOT retried submits exactly
        /// once, and a cancel never submits. Guards against the loop re-submitting on its own.
        func test_singleActiveGuardStillHoldsAcrossRounds() async {
            let sessionId = "sess_retry_2"
            let session = makeSession(id: sessionId, cofEnabled: true)
            let card = SavedCard(id: "pm_1", brand: "visa", last4: "4242", expMonth: 12, expYear: 2030)
            let (controller, payment, _) = makeController(
                session: session,
                cards: [card],
                submit: [PaymentSnapshot(sessionId: sessionId, status: .succeeded, txnId: "ok")]
            )

            let sheet = PaymentSheet(
                controller: controller,
                sessionId: sessionId,
                customerAccessSecret: "secret_abc"
            )

            // One successful confirm → terminal; the present layer would stop looping here.
            let outcome = await sheet.runCheckout { _ in .confirmSavedCard(paymentMethodId: "pm_1") }
            XCTAssertEqual(outcome, .succeeded(txnId: "ok"))
            XCTAssertEqual(payment.submitCallCount, 1, "exactly one submit for one confirm")

            // A subsequent cancel round (user dismisses) must not submit again.
            let canceled = await sheet.runCheckout { _ in .cancel }
            guard case .canceled = canceled else {
                return XCTFail("expected .canceled, got \(canceled)")
            }
            XCTAssertEqual(payment.submitCallCount, 1, "a cancel round must not submit")
        }

        // MARK: - onStateChange bridge

        /// The container forwards the content's `didChangeState` to its `onStateChange` callback,
        /// which `PaymentSheet` wires to the public `onStateChange`.
        @MainActor
        func test_container_forwardsStateChangeToOnStateChange() {
            let session = makeSession(id: "sess_state_1", cofEnabled: false)
            let content = CheckoutContentViewController(
                session: session,
                savedCards: [],
                appearance: .resolve(.default),
                localize: { $0 },
                billingMode: .simple,
                shippingMode: .simple,
                addressService: EmptyAddressMetadataService()
            )
            let container = PaymentSheetContainerViewController(
                content: content,
                appearance: .resolve(.default),
                colorScheme: .automatic
            )

            var observed: CheckoutPresentationState?
            container.onStateChange = { observed = $0 }

            // The container is the content's delegate; drive a confirm so the content emits a state.
            // The new-card form is a subpage now, so open it before filling/tapping Pay.
            content.loadViewIfNeeded()
            content.openNewCardForTest()
            content.fillCardForTest()
            content.simulateTapPay()

            XCTAssertEqual(observed, .processing)
        }
    }
#endif
