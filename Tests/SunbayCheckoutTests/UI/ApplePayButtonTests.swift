#if canImport(UIKit)
    import UIKit
    import XCTest

    @testable import SunbayCheckout

    /// Unit tests for `ApplePayButton` (L3) (iOS only; entirely excluded by `#if canImport(UIKit)` on the macOS host).
    ///
    /// Injects a mock controller (a real `CheckoutController` assembled from the existing `MockPaymentService` /
    /// `MockCofService` / `StubActionHandler`) and a mock `WalletAuthorizing` via the **internal initializer**,
    /// to verify the following without a real device / without PassKit presentation:
    /// 1. an available wallet → `isAvailable == true` and triggers `onAvailabilityChange(true)`;
    /// 2. a tap → drives `onResult` to the scripted outcome (here `.succeeded`).
    ///
    /// Wallet authorization success ≠ transaction success; this test scripts the backend to return `S` so the outcome is `.succeeded`.
    final class ApplePayButtonTests: XCTestCase {
        // MARK: - Assembly helpers

        /// An available Apple Pay session (backend allows `.applePay`, not expired).
        private func availableSession(id: String) -> CheckoutSession {
            CheckoutSession(
                id: id,
                amount: Amount(minorUnits: 999, currencyCode: "USD"),
                merchantName: "Acme",
                methods: [.applePay, .card],
                expiresAt: Date().addingTimeInterval(600),
                rsaPublicKey: nil,
                cofEnabled: false
            )
        }

        /// Assemble a real `CheckoutController` with a mock backend + stub action handler.
        private func makeController(
            session: CheckoutSession,
            submit snapshot: PaymentSnapshot
        ) -> CheckoutController {
            let payment = MockPaymentService()
            payment.stubSession(session)
            payment.stubSubmit([snapshot])
            let cof = MockCofService()
            return CheckoutController(
                paymentService: payment,
                cofService: cof,
                credentials: CredentialStore(),
                actionHandler: StubActionHandler(result: .pending)
            )
        }

        // MARK: - 1. Availability

        func test_construct_withAvailableWallet_isAvailableTrue_andFiresCallback() {
            let sessionId = "sess_apple_1"
            let session = availableSession(id: sessionId)
            let controller = makeController(
                session: session,
                submit: PaymentSnapshot(sessionId: sessionId, status: .succeeded, txnId: "txn_1")
            )
            let wallet = MockWalletAuthorizer(canMake: true, outcome: .success(Data([0x01])))

            let changeExpectation = expectation(description: "onAvailabilityChange(true)")
            var observed: [Bool] = []

            let button = ApplePayButton(
                controller: controller,
                walletAuthorizer: wallet,
                sessionId: sessionId,
                configuredMerchantId: "merchant.com.acme",
                amount: session.amount
            )
            button.onAvailabilityChange = { available in
                observed.append(available)
                if available { changeExpectation.fulfill() }
            }

            wait(for: [changeExpectation], timeout: 2.0)
            XCTAssertTrue(button.isAvailable)
            XCTAssertEqual(observed.last, true)
        }

        // MARK: - 2. Tap drives the result

        func test_tap_drivesOnResult_withScriptedOutcome() {
            let sessionId = "sess_apple_2"
            let session = availableSession(id: sessionId)
            let controller = makeController(
                session: session,
                submit: PaymentSnapshot(sessionId: sessionId, status: .succeeded, txnId: "txn_ok")
            )
            let wallet = MockWalletAuthorizer(canMake: true, outcome: .success(Data([0xAB, 0xCD])))

            // Wait for availability to be ready first, to avoid tapping before the session loads.
            let availableExpectation = expectation(description: "available")
            let resultExpectation = expectation(description: "onResult")
            var received: CheckoutOutcome?

            let button = ApplePayButton(
                controller: controller,
                walletAuthorizer: wallet,
                sessionId: sessionId,
                configuredMerchantId: "merchant.com.acme",
                amount: session.amount
            )
            button.onAvailabilityChange = { available in
                if available { availableExpectation.fulfill() }
            }
            button.onResult = { outcome in
                received = outcome
                resultExpectation.fulfill()
            }

            wait(for: [availableExpectation], timeout: 2.0)
            // In an xctest run without a host app, `UIApplication` is nil and `sendActions(for:)`
            // cannot dispatch control events to the target; so trigger `.touchUpInside` directly via the
            // target-action registry, equivalent to a tap without relying on UIApplication dispatch.
            fireTouchUpInside(on: button)

            wait(for: [resultExpectation], timeout: 2.0)
            guard case .succeeded(let txnId)? = received else {
                return XCTFail("expected .succeeded, got \(String(describing: received))")
            }
            XCTAssertEqual(txnId, "txn_ok")
        }

        // MARK: - Manually trigger control events (no host app environment)

        /// Triggers `.touchUpInside` directly based on the control's target-action registry.
        ///
        /// In an xctest process without a host app, `UIApplication.shared` is nil and `sendActions`
        /// does not dispatch; this reads the target/action the control registered itself and calls it
        /// directly, equivalent to a tap.
        private func fireTouchUpInside(on control: UIControl) {
            for target in control.allTargets {
                let actions = control.actions(forTarget: target, forControlEvent: .touchUpInside) ?? []
                for action in actions {
                    (target as NSObject).perform(Selector(action), with: control)
                }
            }
        }
    }

    // MARK: - Mock WalletAuthorizing

    /// Scriptable double for `WalletAuthorizing`: both device capability and the authorization result can be scripted.
    /// The token `Data` returned by authorization is only used to feed `confirmWallet` and must never appear in results/logs (§5).
    final class MockWalletAuthorizer: WalletAuthorizing, @unchecked Sendable {
        enum Outcome {
            case success(Data)
            case failure(Error)
        }

        private let canMake: Bool
        private let outcome: Outcome

        init(canMake: Bool, outcome: Outcome) {
            self.canMake = canMake
            self.outcome = outcome
        }

        func canMakePayments() -> Bool { canMake }

        func authorize(amount: Amount, merchantId: String) async throws -> Data {
            switch outcome {
            case .success(let data): return data
            case .failure(let error): throw error
            }
        }
    }
#endif
