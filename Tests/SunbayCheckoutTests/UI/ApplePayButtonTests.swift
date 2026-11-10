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

        // MARK: - 3. Wallet cancel vs authorization failure

        /// The user dismissing the Apple Pay sheet (authorizer throws `WALLET_CANCELED`) → `.canceled`
        /// (NOT `.failed`), and no submit happens.
        func test_tap_walletCanceled_drivesOnResultCanceled() {
            let sessionId = "sess_apple_cancel"
            let session = availableSession(id: sessionId)
            let payment = MockPaymentService()
            payment.stubSession(session)
            let controller = CheckoutController(
                paymentService: payment, cofService: MockCofService(),
                credentials: CredentialStore(), actionHandler: StubActionHandler(result: .pending))
            let cancelError = CheckoutError(
                code: "WALLET_CANCELED", message: "canceled", category: .runtime, traceId: nil)
            let wallet = MockWalletAuthorizer(canMake: true, outcome: .failure(cancelError))

            let availableExpectation = expectation(description: "available")
            let resultExpectation = expectation(description: "onResult")
            var received: CheckoutOutcome?

            let button = ApplePayButton(
                controller: controller, walletAuthorizer: wallet, sessionId: sessionId,
                configuredMerchantId: "merchant.com.acme", amount: session.amount)
            button.onAvailabilityChange = { if $0 { availableExpectation.fulfill() } }
            button.onResult = { received = $0; resultExpectation.fulfill() }

            wait(for: [availableExpectation], timeout: 2.0)
            fireTouchUpInside(on: button)

            wait(for: [resultExpectation], timeout: 2.0)
            guard case .canceled? = received else {
                return XCTFail("expected .canceled, got \(String(describing: received))")
            }
            XCTAssertEqual(payment.submitCallCount, 0, "a cancel must not submit")
        }

        /// An authorization failure (authorizer throws a non-cancel error) → `.failed`, and no submit
        /// happens (there is no token to submit).
        func test_tap_walletAuthFailure_drivesOnResultFailed() {
            let sessionId = "sess_apple_fail"
            let session = availableSession(id: sessionId)
            let payment = MockPaymentService()
            payment.stubSession(session)
            let controller = CheckoutController(
                paymentService: payment, cofService: MockCofService(),
                credentials: CredentialStore(), actionHandler: StubActionHandler(result: .pending))
            let authError = CheckoutError(
                code: "WALLET_AUTH_FAILED", message: "auth failed", category: .runtime, traceId: nil)
            let wallet = MockWalletAuthorizer(canMake: true, outcome: .failure(authError))

            let availableExpectation = expectation(description: "available")
            let resultExpectation = expectation(description: "onResult")
            var received: CheckoutOutcome?

            let button = ApplePayButton(
                controller: controller, walletAuthorizer: wallet, sessionId: sessionId,
                configuredMerchantId: "merchant.com.acme", amount: session.amount)
            button.onAvailabilityChange = { if $0 { availableExpectation.fulfill() } }
            button.onResult = { received = $0; resultExpectation.fulfill() }

            wait(for: [availableExpectation], timeout: 2.0)
            fireTouchUpInside(on: button)

            wait(for: [resultExpectation], timeout: 2.0)
            guard case .failed(_, let error)? = received else {
                return XCTFail("expected .failed, got \(String(describing: received))")
            }
            XCTAssertEqual(error.code, "WALLET_AUTH_FAILED")
            XCTAssertEqual(payment.submitCallCount, 0, "an auth failure must not submit")
        }

        // MARK: - Host addresses

        /// Setting / clearing the public address properties reaches the controller's host entries.
        @MainActor
        func test_hostAddressSetters_reachController() async throws {
            let sessionId = "sess_addr_button"
            let session = CheckoutSession(
                id: sessionId, amount: Amount(minorUnits: 999, currencyCode: "USD"), merchantName: "Acme",
                methods: [.applePay, .card], expiresAt: Date().addingTimeInterval(600),
                rsaPublicKey: nil, cofEnabled: false, collectBillingAddress: true)
            let payment = MockPaymentService()
            payment.stubSession(session)
            let controller = CheckoutController(
                paymentService: payment, cofService: MockCofService(), credentials: CredentialStore(),
                actionHandler: StubActionHandler(result: .pending))
            let button = ApplePayButton(
                controller: controller,
                walletAuthorizer: MockWalletAuthorizer(canMake: true, outcome: .success(Data([1]))),
                sessionId: sessionId, configuredMerchantId: "merchant.test")
            let complete = AddressInput(country: "US", line1: "1 Main", city: "SF", postalCode: "94103")

            button.billingAddress = complete
            try await waitForBillingEntry(controller, equals: complete)

            button.billingAddress = nil
            try await waitForBillingEntry(controller, equals: nil)
        }

        private func waitForBillingEntry(
            _ controller: CheckoutController, equals expected: AddressInput?
        ) async throws {
            let deadline = Date().addingTimeInterval(5)
            while await controller.usableHostEntry(.billing) != expected, Date() < deadline {
                try await Task.sleep(nanoseconds: 20_000_000)
            }
            let actual = await controller.usableHostEntry(.billing)
            XCTAssertEqual(actual, expected)
        }

        // MARK: - Contacts, addresses and ewalletParam

        private func collectingSession(id: String) -> CheckoutSession {
            CheckoutSession(
                id: id, amount: Amount(minorUnits: 999, currencyCode: "USD"), merchantName: "Acme",
                methods: [.applePay, .card], expiresAt: Date().addingTimeInterval(600),
                rsaPublicKey: nil, cofEnabled: false,
                collectBillingAddress: true, collectShippingAddress: true)
        }

        func test_tap_requestsContactsFromController_andSubmitsReturnedAddressesAndEmail() {
            let sessionId = "sess_apple_contacts"
            let session = collectingSession(id: sessionId)
            let payment = MockPaymentService()
            payment.stubSession(session)
            payment.stubSubmit([PaymentSnapshot(sessionId: sessionId, status: .succeeded, txnId: "txn_ok")])
            let controller = CheckoutController(
                paymentService: payment, cofService: MockCofService(), credentials: CredentialStore(),
                actionHandler: StubActionHandler(result: .pending))
            let billing = AddressInput(country: "US", line1: "1 Main", city: "SF", postalCode: "94103")
            let shipping = AddressInput(
                country: "US", line1: "2 Side", city: "LA", postalCode: "90001",
                firstName: "Ada", lastName: "Lovelace", phone: "+14155550100")
            let wallet = MockWalletAuthorizer(
                canMake: true,
                outcome: .authorization(
                    WalletAuthorization(token: Data([9]), billing: billing, shipping: shipping, email: "a@b.co")))
            let button = ApplePayButton(
                controller: controller, walletAuthorizer: wallet, sessionId: sessionId,
                configuredMerchantId: "merchant.com.acme")
            let available = expectation(description: "available")
            let result = expectation(description: "result")
            button.onAvailabilityChange = { if $0 { available.fulfill() } }
            button.onResult = { _ in result.fulfill() }
            wait(for: [available], timeout: 2.0)

            fireTouchUpInside(on: button)
            wait(for: [result], timeout: 2.0)

            XCTAssertEqual(wallet.lastContacts, WalletContactRequest(billing: true, shipping: true))
            XCTAssertEqual(wallet.lastMerchantName, "Acme")
            XCTAssertEqual(payment.lastSubmitRequest?.billingAddress, billing)
            XCTAssertEqual(payment.lastSubmitRequest?.shippingAddress, shipping)
            XCTAssertEqual(payment.lastSubmitRequest?.customerEmail, "a@b.co")
        }

        func test_missingWalletParameters_buttonUnavailable_andOneWarningWithNamesOnly() {
            let sessionId = "sess_apple_invalid"
            let session = availableSession(id: sessionId)
            let payment = MockPaymentService()
            payment.stubSession(session)
            let reporter = DiagnosticsReporter()
            let delivered = expectation(description: "warning")
            nonisolated(unsafe) var warnings: [CheckoutWarning] = []
            reporter.handler = { event in
                if case .warning(let w) = event { warnings.append(w); delivered.fulfill() }
            }
            let controller = CheckoutController(
                paymentService: payment, cofService: MockCofService(), credentials: CredentialStore(),
                actionHandler: StubActionHandler(result: .pending), reporter: reporter)
            let wallet = MockWalletAuthorizer(
                canMake: true, outcome: .success(Data([1])), missing: ["supportedNetworks"])
            let button = ApplePayButton(
                controller: controller, walletAuthorizer: wallet, sessionId: sessionId,
                configuredMerchantId: "merchant.com.acme")

            wait(for: [delivered], timeout: 2.0)
            RunLoop.main.run(until: Date().addingTimeInterval(0.2))

            XCTAssertFalse(button.isAvailable)
            XCTAssertEqual(warnings.count, 1)
            XCTAssertEqual(warnings.first?.code, .walletParamsInvalid)
            XCTAssertEqual(warnings.first?.ignored, ["supportedNetworks"])
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
            case authorization(WalletAuthorization)
            case failure(Error)
        }

        private let canMake: Bool
        private let outcome: Outcome
        private let missing: [String]
        private let lock = NSLock()
        private var _lastContacts: WalletContactRequest?
        private var _lastMerchantName: String?

        init(canMake: Bool, outcome: Outcome, missing: [String] = []) {
            self.canMake = canMake
            self.outcome = outcome
            self.missing = missing
        }

        /// The contacts passed to the most recent `authorize` call.
        var lastContacts: WalletContactRequest? { lock.lock(); defer { lock.unlock() }; return _lastContacts }
        var lastMerchantName: String? { lock.lock(); defer { lock.unlock() }; return _lastMerchantName }

        private func record(contacts: WalletContactRequest, merchantName: String) {
            lock.lock()
            _lastContacts = contacts
            _lastMerchantName = merchantName
            lock.unlock()
        }

        func canMakePayments() -> Bool { canMake }

        func missingParameters(for params: ApplePayParams?) -> [String] { missing }

        func authorize(
            amount: Amount,
            merchantId: String,
            merchantName: String,
            params: ApplePayParams?,
            contacts: WalletContactRequest,
            confirm: @escaping @Sendable (WalletAuthorization) async -> CheckoutOutcome
        ) async throws -> CheckoutOutcome {
            record(contacts: contacts, merchantName: merchantName)
            switch outcome {
            case .success(let data):
                return await confirm(WalletAuthorization(token: data, billing: nil, shipping: nil, email: nil))
            case .authorization(let authorization): return await confirm(authorization)
            case .failure(let error): throw error
            }
        }
    }
#endif
