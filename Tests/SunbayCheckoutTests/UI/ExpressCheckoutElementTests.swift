#if canImport(UIKit)
    import UIKit
    import XCTest

    #if canImport(PassKit)
        import PassKit
    #endif

    @testable import SunbayCheckout

    /// Tests for `CheckoutElements` + `ExpressCheckoutElement` (iOS only).
    ///
    /// A real `CheckoutController` is assembled from the mock backend and a stub `WalletAuthorizing` is
    /// injected through the internal `CheckoutElements.create` overload, so nothing needs the network or
    /// PassKit presentation. Wallet authorization success is not transaction success: the scripted backend
    /// decides the outcome.
    @MainActor
    final class ExpressCheckoutElementTests: XCTestCase {
        private let merchantId = "merchant.com.acme"

        // MARK: - Assembly helpers

        private func session(
            id: String, billing: Bool = false, shipping: Bool = false,
            methods: Set<PaymentMethodKind> = [.applePay, .card]
        ) -> CheckoutSession {
            CheckoutSession(
                id: id, amount: Amount(minorUnits: 999, currencyCode: "USD"), merchantName: "Acme",
                methods: methods, expiresAt: Date().addingTimeInterval(600),
                rsaPublicKey: nil, cofEnabled: false,
                collectBillingAddress: billing, collectShippingAddress: shipping)
        }

        private func makeController(
            _ session: CheckoutSession, submit: [PaymentSnapshot] = [], reporter: DiagnosticsReporter? = nil,
            credentials: CredentialStore = CredentialStore()
        ) -> (CheckoutController, MockPaymentService) {
            let payment = MockPaymentService()
            payment.stubSession(session)
            if !submit.isEmpty { payment.stubSubmit(submit) }
            let controller = CheckoutController(
                paymentService: payment, cofService: MockCofService(), credentials: credentials,
                actionHandler: StubActionHandler(result: .pending), reporter: reporter)
            return (controller, payment)
        }

        private func makeElements(
            _ controller: CheckoutController, sessionId: String, wallet: any WalletAuthorizing,
            merchantId: String? = "merchant.com.acme", filter: PaymentMethodFilter = PaymentMethodFilter(),
            appearance: Appearance = .default, customerAccessSecret: String? = nil
        ) async throws -> CheckoutElements {
            var configuration = CheckoutElements.Configuration()
            configuration.customerAccessSecret = customerAccessSecret
            return try await CheckoutElements.create(
                controller: controller, sessionId: sessionId, configuration: configuration,
                appearance: appearance, walletAuthorizer: wallet, walletMerchantId: merchantId,
                paymentMethodFilter: filter)
        }

        private func succeeded(_ id: String, txn: String = "txn_ok") -> PaymentSnapshot {
            PaymentSnapshot(sessionId: id, status: .succeeded, txnId: txn)
        }

        /// Taps and waits for the next `onResult`.
        private func tap(_ element: ExpressCheckoutElement) async -> CheckoutOutcome {
            await withCheckedContinuation { (continuation: CheckedContinuation<CheckoutOutcome, Never>) in
                element.onResult = { continuation.resume(returning: $0) }
                element.simulateTap()
            }
        }

        // MARK: - Availability

        func test_available_whenDeviceMerchantIdAndSessionAllow_firesCallback() async throws {
            let id = "sess_apple_1"
            let (controller, _) = makeController(session(id: id))
            let elements = try await makeElements(
                controller, sessionId: id, wallet: MockWalletAuthorizer(canMake: true, outcome: .success(Data([1]))))
            let express = elements.makeExpressCheckoutElement()
            let fired = expectation(description: "onAvailabilityChange(true)")
            express.onAvailabilityChange = { if $0 { fired.fulfill() } }
            await fulfillment(of: [fired], timeout: 2)
            XCTAssertTrue(express.isAvailable)
        }

        func test_filterHidesApplePay_isUnavailable_andReportsFalseOnce() async throws {
            let id = "sess_apple_hidden"
            let (controller, _) = makeController(session(id: id))
            let elements = try await makeElements(
                controller, sessionId: id, wallet: MockWalletAuthorizer(canMake: true, outcome: .success(Data([1]))),
                filter: PaymentMethodFilter(hide: ["APPLE_PAY"]))
            let express = elements.makeExpressCheckoutElement()
            let fired = expectation(description: "onAvailabilityChange(false)")
            var values: [Bool] = []
            express.onAvailabilityChange = { values.append($0); fired.fulfill() }
            await fulfillment(of: [fired], timeout: 2)
            try await Task.sleep(nanoseconds: 100_000_000)
            XCTAssertFalse(express.isAvailable)
            XCTAssertEqual(values, [false])
        }

        func test_methodsApplePayOnly_showsOnlyApplePay() async throws {
            let id = "sess_apple_methods"
            let (controller, _) = makeController(session(id: id))
            let elements = try await makeElements(
                controller, sessionId: id, wallet: MockWalletAuthorizer(canMake: true, outcome: .success(Data([1]))))
            var applePayOnly = ExpressCheckoutElement.Configuration()
            applePayOnly.methods = [.applePay]
            XCTAssertTrue(elements.makeExpressCheckoutElement(applePayOnly).isAvailable)
            var none = ExpressCheckoutElement.Configuration()
            none.methods = []
            XCTAssertFalse(elements.makeExpressCheckoutElement(none).isAvailable)
        }

        func test_noApplePayAvailable_isUnavailable_andViewHasZeroHeight() async throws {
            let id = "sess_apple_nodevice"
            let (controller, _) = makeController(session(id: id))
            let elements = try await makeElements(
                controller, sessionId: id, wallet: MockWalletAuthorizer(canMake: false, outcome: .success(Data([1]))))
            let express = elements.makeExpressCheckoutElement()
            XCTAssertFalse(express.isAvailable)
            XCTAssertEqual(express.view.systemLayoutSizeFitting(UIView.layoutFittingCompressedSize).height, 0)
        }

        func test_expressPositionOff_hidesApplePay() async throws {
            let id = "sess_apple_off"
            let (controller, _) = makeController(session(id: id))
            var appearance = Appearance()
            appearance.expressPosition = .off
            let elements = try await makeElements(
                controller, sessionId: id, wallet: MockWalletAuthorizer(canMake: true, outcome: .success(Data([1]))),
                appearance: appearance)
            XCTAssertFalse(elements.makeExpressCheckoutElement().isAvailable)
        }

        func test_missingWalletParameters_unavailable_andOneWarningWithNamesOnly() async throws {
            let id = "sess_apple_invalid"
            let reporter = DiagnosticsReporter()
            let delivered = expectation(description: "warning")
            nonisolated(unsafe) var warnings: [CheckoutWarning] = []
            reporter.handler = { event in
                if case .warning(let w) = event { warnings.append(w); delivered.fulfill() }
            }
            let (controller, _) = makeController(session(id: id), reporter: reporter)
            let wallet = MockWalletAuthorizer(
                canMake: true, outcome: .success(Data([1])), missing: ["supportedNetworks"])
            let elements = try await makeElements(controller, sessionId: id, wallet: wallet)
            let express = elements.makeExpressCheckoutElement()

            await fulfillment(of: [delivered], timeout: 2)
            try await Task.sleep(nanoseconds: 200_000_000)

            XCTAssertFalse(express.isAvailable)
            XCTAssertEqual(warnings.count, 1)
            XCTAssertEqual(warnings.first?.code, .walletParamsInvalid)
            XCTAssertEqual(warnings.first?.ignored, ["supportedNetworks"])
        }

        // MARK: - create

        func test_createWithAllMethodsHidden_doesNotThrow() async throws {
            let id = "sess_all_hidden"
            let (controller, _) = makeController(session(id: id))
            let elements = try await makeElements(
                controller, sessionId: id, wallet: MockWalletAuthorizer(canMake: true, outcome: .success(Data([1]))),
                filter: PaymentMethodFilter(hide: ["APPLE_PAY", "CARD"]))
            XCTAssertFalse(elements.makeExpressCheckoutElement().isAvailable)
            XCTAssertFalse(elements.makeCardElement().isAvailable)
        }

        func test_createWithSessionLoadFailure_throwsCheckoutError() async {
            let payment = MockPaymentService()
            payment.stubLoadError(URLError(.notConnectedToInternet))
            let controller = CheckoutController(
                paymentService: payment, cofService: MockCofService(), credentials: CredentialStore(),
                actionHandler: StubActionHandler(result: .pending))
            do {
                _ = try await makeElements(
                    controller, sessionId: "sess_fail",
                    wallet: MockWalletAuthorizer(canMake: true, outcome: .success(Data([1]))))
                XCTFail("expected create to throw")
            } catch {
                XCTAssertNotNil(error as? CheckoutError)
            }
        }

        func test_createWithSessionLoadFailure_dismissesTheDriver_secretCleared() async {
            let credentials = CredentialStore()
            let payment = MockPaymentService()
            payment.stubLoadError(URLError(.notConnectedToInternet))
            let controller = CheckoutController(
                paymentService: payment, cofService: MockCofService(), credentials: credentials,
                actionHandler: StubActionHandler(result: .pending))
            do {
                _ = try await makeElements(
                    controller, sessionId: "sess_fail_secret",
                    wallet: MockWalletAuthorizer(canMake: true, outcome: .success(Data([1]))),
                    customerAccessSecret: "secret_abc")
                XCTFail("expected create to throw")
            } catch {
                XCTAssertNotNil(error as? CheckoutError)
            }
            let held = await credentials.current()
            XCTAssertNil(held, "a failed create must not leave the credential in memory")
        }

        // MARK: - Tap drives the result

        func test_tap_drivesOnResult_succeeded() async throws {
            let id = "sess_apple_2"
            let (controller, _) = makeController(session(id: id), submit: [succeeded(id)])
            let elements = try await makeElements(
                controller, sessionId: id,
                wallet: MockWalletAuthorizer(canMake: true, outcome: .success(Data([0xAB, 0xCD]))))
            let outcome = await tap(elements.makeExpressCheckoutElement())
            XCTAssertEqual(outcome, .succeeded(txnId: "txn_ok"))
        }

        func test_tap_walletCanceled_drivesOnResultCanceled() async throws {
            let id = "sess_apple_cancel"
            let (controller, payment) = makeController(session(id: id))
            let cancel = CheckoutError(code: "WALLET_CANCELED", message: "canceled", category: .runtime, traceId: nil)
            let elements = try await makeElements(
                controller, sessionId: id, wallet: MockWalletAuthorizer(canMake: true, outcome: .failure(cancel)))
            let outcome = await tap(elements.makeExpressCheckoutElement())
            XCTAssertEqual(outcome, .canceled)
            XCTAssertEqual(payment.submitCallCount, 0, "a cancel must not submit")
        }

        func test_tap_walletAuthFailure_drivesOnResultFailed() async throws {
            let id = "sess_apple_fail"
            let (controller, payment) = makeController(session(id: id))
            let authError = CheckoutError(
                code: "WALLET_AUTH_FAILED", message: "auth failed", category: .runtime, traceId: nil)
            let elements = try await makeElements(
                controller, sessionId: id, wallet: MockWalletAuthorizer(canMake: true, outcome: .failure(authError)))
            let outcome = await tap(elements.makeExpressCheckoutElement())
            guard case let .failed(_, error) = outcome else { return XCTFail("expected .failed, got \(outcome)") }
            XCTAssertEqual(error.code, "WALLET_AUTH_FAILED")
            XCTAssertEqual(payment.submitCallCount, 0, "an auth failure must not submit")
        }

        func test_tap_requestsContactsFromController_andSubmitsReturnedAddressesAndEmail() async throws {
            let id = "sess_apple_contacts"
            let (controller, payment) = makeController(
                session(id: id, billing: true, shipping: true), submit: [succeeded(id)])
            let billing = AddressInput(country: "US", line1: "1 Main", city: "SF", postalCode: "94103")
            let shipping = AddressInput(
                country: "US", line1: "2 Side", city: "LA", postalCode: "90001",
                firstName: "Ada", lastName: "Lovelace", phone: "+14155550100")
            let wallet = MockWalletAuthorizer(
                canMake: true,
                outcome: .authorization(
                    WalletAuthorization(token: Data([9]), billing: billing, shipping: shipping, email: "a@b.co")))
            let elements = try await makeElements(controller, sessionId: id, wallet: wallet)

            _ = await tap(elements.makeExpressCheckoutElement())

            XCTAssertEqual(wallet.lastContacts, WalletContactRequest(billing: true, shipping: true))
            XCTAssertEqual(wallet.lastMerchantName, "Acme")
            XCTAssertEqual(payment.lastSubmitRequest?.billingAddress, billing)
            XCTAssertEqual(payment.lastSubmitRequest?.shippingAddress, shipping)
            XCTAssertEqual(payment.lastSubmitRequest?.customerEmail, "a@b.co")
        }

        func test_tap_whileAnotherPaymentInFlight_reportsAlreadyPresenting() async throws {
            let id = "sess_apple_busy"
            let (controller, _) = makeController(session(id: id), submit: [succeeded(id)])
            let wallet = BlockingWalletAuthorizer()
            let elements = try await makeElements(controller, sessionId: id, wallet: wallet)
            let express = elements.makeExpressCheckoutElement()

            let first = expectation(description: "first result")
            var results: [CheckoutOutcome] = []
            express.onResult = { results.append($0); if results.count == 2 { first.fulfill() } }
            express.simulateTap()
            await wallet.waitUntilAuthorizing()
            express.simulateTap()
            try await Task.sleep(nanoseconds: 100_000_000)
            XCTAssertEqual(results, [.failed(txnId: nil, error: CheckoutErrors.alreadyPresenting())])

            wallet.release()
            await fulfillment(of: [first], timeout: 2)
            XCTAssertEqual(results.last, .succeeded(txnId: "txn_ok"))
        }

        // MARK: - Host addresses

        func test_updateAddresses_reachesController() async throws {
            let id = "sess_addr_button"
            let (controller, _) = makeController(session(id: id, billing: true))
            let elements = try await makeElements(
                controller, sessionId: id, wallet: MockWalletAuthorizer(canMake: true, outcome: .success(Data([1]))))
            let complete = AddressInput(country: "US", line1: "1 Main", city: "SF", postalCode: "94103")

            elements.updateAddresses(billing: complete, shipping: nil)
            try await waitForBillingEntry(controller, equals: complete)

            elements.updateAddresses(billing: nil, shipping: nil)
            try await waitForBillingEntry(controller, equals: nil)
        }

        private func waitForBillingEntry(_ controller: CheckoutController, equals expected: AddressInput?) async throws {
            let deadline = Date().addingTimeInterval(5)
            while await controller.usableHostEntry(.billing) != expected, Date() < deadline {
                try await Task.sleep(nanoseconds: 20_000_000)
            }
            let actual = await controller.usableHostEntry(.billing)
            XCTAssertEqual(actual, expected)
        }

        // MARK: - close

        func test_close_dismissesTheController_secretsCleared() async throws {
            let id = "sess_close"
            let credentials = CredentialStore()
            let (controller, _) = makeController(session(id: id), credentials: credentials)
            let elements = try await makeElements(
                controller, sessionId: id, wallet: MockWalletAuthorizer(canMake: true, outcome: .success(Data([1]))),
                customerAccessSecret: "secret_abc")
            let express = elements.makeExpressCheckoutElement()
            let before = await credentials.current()
            XCTAssertEqual(before, "secret_abc")
            await elements.closeAndWait()
            let after = await credentials.current()
            XCTAssertNil(after, "close() dismisses the controller, which clears the credential")
            let outcome = await tap(express)
            XCTAssertEqual(outcome, .canceled, "taps after close are ignored, not paid")
        }

        func test_releasingTheGroup_dismissesTheController_secretsCleared() async throws {
            let id = "sess_deinit"
            let credentials = CredentialStore()
            let (controller, _) = makeController(session(id: id), credentials: credentials)
            var elements: CheckoutElements? = try await makeElements(
                controller, sessionId: id, wallet: MockWalletAuthorizer(canMake: true, outcome: .success(Data([1]))),
                customerAccessSecret: "secret_abc")
            let held = await credentials.current()
            XCTAssertEqual(held, "secret_abc")
            elements = nil
            let deadline = Date().addingTimeInterval(5)
            while await credentials.current() != nil, Date() < deadline {
                try await Task.sleep(nanoseconds: 20_000_000)
            }
            let after = await credentials.current()
            XCTAssertNil(after, "deinit of the group dismisses the controller even without close()")
        }

        // MARK: - Button overrides

        #if canImport(PassKit)
            private func expressView(of element: ExpressCheckoutElement) throws -> ExpressCheckoutView {
                try XCTUnwrap(element.view.subviews.compactMap { $0 as? ExpressCheckoutView }.first)
            }

            func test_buttonOverrides_reachThePKPaymentButton() async throws {
                let id = "sess_button_overrides"
                let (controller, _) = makeController(session(id: id))
                let elements = try await makeElements(
                    controller, sessionId: id, wallet: MockWalletAuthorizer(canMake: true, outcome: .success(Data([1]))))
                var configuration = ExpressCheckoutElement.Configuration()
                configuration.buttonType = .donate
                configuration.buttonStyle = .white
                let overridden = try expressView(of: elements.makeExpressCheckoutElement(configuration))
                XCTAssertEqual(overridden.appliedButtonTypeForTest, ApplePayButtonType.donate.pkType)
                XCTAssertEqual(overridden.appliedButtonStyleForTest, Appearance.ApplePayButtonStyle.white.pkStyle)
                XCTAssertTrue(overridden.paymentButtonForTest is PKPaymentButton)

                let defaulted = try expressView(of: elements.makeExpressCheckoutElement())
                XCTAssertEqual(defaulted.appliedButtonTypeForTest, Appearance.default.applePayButtonType.pkType)
                XCTAssertEqual(defaulted.appliedButtonStyleForTest, Appearance.default.applePayButtonStyle.pkStyle)
            }
        #endif
    }

    // MARK: - Doubles

    /// A wallet that stays inside `authorize` until released, so a second tap can race the first.
    final class BlockingWalletAuthorizer: WalletAuthorizing, @unchecked Sendable {
        private let lock = NSLock()
        private var releaseContinuation: CheckedContinuation<Void, Never>?
        private var authorizing = false
        private var released = false

        func canMakePayments() -> Bool { true }
        func missingParameters(for params: ApplePayParams?) -> [String] { [] }

        func authorize(
            amount: Amount, merchantId: String, merchantName: String, params: ApplePayParams?,
            contacts: WalletContactRequest,
            confirm: @escaping @Sendable (WalletAuthorization) async -> CheckoutOutcome
        ) async throws -> CheckoutOutcome {
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                lock.lock()
                authorizing = true
                if released {
                    lock.unlock()
                    continuation.resume()
                } else {
                    releaseContinuation = continuation
                    lock.unlock()
                }
            }
            return await confirm(WalletAuthorization(token: Data([1]), billing: nil, shipping: nil, email: nil))
        }

        func waitUntilAuthorizing() async {
            while !isAuthorizing {
                try? await Task.sleep(nanoseconds: 10_000_000)
            }
        }

        private var isAuthorizing: Bool {
            lock.lock()
            defer { lock.unlock() }
            return authorizing
        }

        func release() {
            lock.lock()
            released = true
            let continuation = releaseContinuation
            releaseContinuation = nil
            lock.unlock()
            continuation?.resume()
        }
    }

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
