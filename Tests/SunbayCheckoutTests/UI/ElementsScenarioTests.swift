#if canImport(UIKit)
    import UIKit
    import XCTest

    @testable import SunbayCheckout

    /// Typical merchant-page scenarios for the Elements embedding mode (iOS only).
    ///
    /// Every test models one checkout page: ONE `CheckoutElements` group, an `ExpressCheckoutElement` and a
    /// `CardElement` created from it, both views laid out in a window, and a merchant "Pay" that calls
    /// `elements.confirm()`. Backends are the scripted mocks; the card is the public test PAN.
    @MainActor
    final class ElementsScenarioTests: XCTestCase {
        private let usable = SavedCard(id: "pm_ok", brand: "visa", last4: "4242", expMonth: 12, expYear: 2099)

        /// One merchant page: the group, both elements, the window that hosts them, and the backend doubles.
        @MainActor
        private struct Page {
            let elements: CheckoutElements
            let express: ExpressCheckoutElement
            let card: CardElement
            let window: UIWindow
            let payment: MockPaymentService
            let credentials: CredentialStore

            /// The PassKit-button host inside the express element (nil while unavailable).
            var expressButton: ExpressCheckoutView? {
                express.view.subviews.compactMap { $0 as? ExpressCheckoutView }.first
            }
        }

        // MARK: - Page assembly

        private func makePage(
            id: String, cards: [SavedCard] = [], billing: Bool = false, submit: [PaymentSnapshot] = [],
            submitDelay: Duration? = nil, withKey: Bool = false, expiresIn: TimeInterval = 600,
            filter: PaymentMethodFilter = PaymentMethodFilter()
        ) async throws -> Page {
            let payment = MockPaymentService()
            payment.stubSession(
                CheckoutSession(
                    id: id, amount: Amount(minorUnits: 999, currencyCode: "USD"), merchantName: "Acme",
                    methods: [.applePay, .card, .savedCard], expiresAt: Date().addingTimeInterval(expiresIn),
                    rsaPublicKey: withKey ? try PaymentSheetTests.makeRSAPublicKeyBase64(bits: 2048) : nil,
                    cofEnabled: true, collectBillingAddress: billing, collectShippingAddress: false))
            if !submit.isEmpty { payment.stubSubmit(submit) }
            if let submitDelay { payment.stubSubmitDelay(submitDelay) }
            let cof = MockCofService()
            cof.stubCards(cards)
            let credentials = CredentialStore()
            let controller = CheckoutController(
                paymentService: payment, cofService: cof, credentials: credentials,
                actionHandler: StubActionHandler(result: .pending))
            var configuration = CheckoutElements.Configuration()
            configuration.customerAccessSecret = "secret_abc"
            let elements = try await CheckoutElements.create(
                controller: controller, sessionId: id, configuration: configuration,
                walletAuthorizer: MockWalletAuthorizer(canMake: true, outcome: .success(Data([1]))),
                walletMerchantId: "merchant.com.acme", paymentMethodFilter: filter)
            let express = elements.makeExpressCheckoutElement()
            let card = elements.makeCardElement()

            let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 375, height: 900))
            let controllerVC = UIViewController()
            window.rootViewController = controllerVC
            window.makeKeyAndVisible()
            let stack = UIStackView(arrangedSubviews: [express.view, card.view])
            stack.axis = .vertical
            stack.spacing = 12
            stack.frame = CGRect(x: 0, y: 40, width: 375, height: 800)
            controllerVC.view.addSubview(stack)
            window.layoutIfNeeded()
            return Page(
                elements: elements, express: express, card: card, window: window, payment: payment,
                credentials: credentials)
        }

        private func snapshot(_ id: String, _ status: TxnStatus) -> PaymentSnapshot {
            PaymentSnapshot(sessionId: id, status: status, txnId: "txn_1")
        }

        /// Polls the main actor until `condition` holds or the deadline passes.
        private func waitUntil(
            timeout: TimeInterval = 5, _ message: String, file: StaticString = #filePath, line: UInt = #line,
            _ condition: () -> Bool
        ) async {
            let deadline = Date().addingTimeInterval(timeout)
            while !condition(), Date() < deadline { try? await Task.sleep(nanoseconds: 10_000_000) }
            XCTAssertTrue(condition(), message, file: file, line: line)
        }

        private func expectFailed(
            _ outcome: CheckoutOutcome, code: String, file: StaticString = #filePath, line: UInt = #line
        ) {
            guard case let .failed(_, error) = outcome else {
                return XCTFail("expected .failed(\(code)), got \(outcome)", file: file, line: line)
            }
            XCTAssertEqual(error.code, code, file: file, line: line)
        }

        // MARK: - 1

        func test_scenario_savedCard_pay_succeeds_andLocksEverything() async throws {
            let id = "scn_saved"
            let page = try await makePage(id: id, cards: [usable], submit: [snapshot(id, .succeeded)])
            // Preconditions: saved card selected, everything live, credential held.
            XCTAssertEqual(page.card.selectedSavedCardIdForTest, "pm_ok")
            XCTAssertTrue(page.card.isComplete)
            XCTAssertTrue(page.card.isInteractiveForTest)
            XCTAssertTrue(page.express.isAvailable)
            XCTAssertEqual(page.expressButton?.isUserInteractionEnabled, true)
            let heldBefore = await page.credentials.current()
            XCTAssertEqual(heldBefore, "secret_abc")

            let outcome = await page.elements.confirm()

            XCTAssertEqual(outcome, .succeeded(txnId: "txn_1"))
            XCTAssertFalse(page.card.isInteractiveForTest, "card element disabled")
            XCTAssertEqual(page.expressButton?.isUserInteractionEnabled, false, "express element disabled")
            let again = await page.elements.confirm()
            XCTAssertEqual(again, .succeeded(txnId: "txn_1"))
            XCTAssertEqual(page.payment.submitCallCount, 1, "no second submit")
            let heldAfter = await page.credentials.current()
            XCTAssertNil(heldAfter, "controller credential cleared")
        }

        // MARK: - 2

        func test_scenario_newCard_invalidThenValid_submitsOnce() async throws {
            let id = "scn_new"
            let page = try await makePage(id: id, submit: [snapshot(id, .succeeded)], withKey: true)
            let entry = try XCTUnwrap(page.card.newCardEntryForTest)
            entry.typePANForTest("4242424242424242")  // number only: no expiry / CVV
            XCTAssertFalse(page.card.isComplete)
            XCTAssertFalse(entry.hasCardFieldError, "no error before the merchant presses Pay")

            let invalid = await page.elements.confirm()

            expectFailed(invalid, code: "CARD_INPUT_INVALID")
            XCTAssertEqual(page.payment.submitCallCount, 0)
            XCTAssertTrue(entry.hasCardFieldError, "inline field error is shown")

            entry.fillCardForTest()
            XCTAssertTrue(page.card.isComplete)
            let valid = await page.elements.confirm()
            XCTAssertEqual(valid, .succeeded(txnId: "txn_1"))
            XCTAssertEqual(page.payment.submitCallCount, 1)
        }

        // MARK: - 3

        func test_scenario_failedPayment_keepsForm_retrySucceeds() async throws {
            let id = "scn_retry"
            let page = try await makePage(
                id: id, submit: [snapshot(id, .failed), snapshot(id, .succeeded)], withKey: true)
            let entry = try XCTUnwrap(page.card.newCardEntryForTest)
            entry.fillCardForTest()
            XCTAssertTrue(page.card.isComplete)

            let first = await page.elements.confirm()

            guard case .failed = first else { return XCTFail("expected .failed, got \(first)") }
            XCTAssertEqual(page.payment.submitCallCount, 1)
            XCTAssertTrue(page.card.isComplete, "typed form kept")
            XCTAssertFalse(entry.panTextForTest.isEmpty)
            XCTAssertTrue(page.card.isNewCardFormVisibleForTest, "selection kept")
            XCTAssertTrue(page.card.isInteractiveForTest)
            XCTAssertEqual(page.expressButton?.isUserInteractionEnabled, true)

            let second = await page.elements.confirm()
            XCTAssertEqual(second, .succeeded(txnId: "txn_1"))
            XCTAssertEqual(page.payment.submitCallCount, 2)
        }

        // MARK: - 4

        func test_scenario_pending_locksAndDoesNotResubmit() async throws {
            let id = "scn_pending"
            let page = try await makePage(id: id, submit: [snapshot(id, .initial)], withKey: true)
            let entry = try XCTUnwrap(page.card.newCardEntryForTest)
            entry.fillCardForTest()
            XCTAssertFalse(entry.panTextForTest.isEmpty, "precondition: a card is typed")

            let first = await page.elements.confirm()

            guard case .pending = first else { return XCTFail("expected .pending, got \(first)") }
            XCTAssertFalse(page.card.isInteractiveForTest)
            XCTAssertEqual(page.expressButton?.isUserInteractionEnabled, false)
            XCTAssertEqual(entry.panTextForTest, "", "typed card cleared")
            let second = await page.elements.confirm()
            XCTAssertEqual(second, first)
            XCTAssertEqual(page.payment.submitCallCount, 1)
        }

        // MARK: - 5

        func test_scenario_expressTap_whileCardConfirmInFlight_reportsAlreadyPresenting() async throws {
            let id = "scn_busy"
            let page = try await makePage(
                id: id, cards: [usable], submit: [snapshot(id, .succeeded)], submitDelay: .milliseconds(600))
            let pay = Task { await page.elements.confirm() }
            await waitUntil("card confirm reaches the submit") { page.payment.submitCallCount == 1 }
            XCTAssertEqual(page.elements.coordinator.state, .confirming, "precondition: submit held in flight")

            let tapResult: CheckoutOutcome = await withCheckedContinuation { continuation in
                page.express.onResult = { continuation.resume(returning: $0) }
                page.express.simulateTap()
            }

            expectFailed(tapResult, code: "ALREADY_PRESENTING")
            let paid = await pay.value
            XCTAssertEqual(paid, .succeeded(txnId: "txn_1"), "the in-flight card payment is unaffected")
            XCTAssertEqual(page.payment.submitCallCount, 1, "exactly one submit")
        }

        // MARK: - 6

        func test_scenario_updateAddresses_thenConfirm_usesNewAddress() async throws {
            let id = "scn_addr"
            let page = try await makePage(
                id: id, cards: [usable], billing: true, submit: [snapshot(id, .succeeded)])
            let address = AddressInput(country: "US", line1: "9 New St", city: "SF", postalCode: "94103")

            page.elements.updateAddresses(billing: address, shipping: nil)
            let outcome = await page.elements.confirm()

            XCTAssertEqual(outcome, .succeeded(txnId: "txn_1"))
            XCTAssertEqual(page.payment.submitCallCount, 1)
            XCTAssertEqual(page.payment.lastSubmitRequest?.billingAddress, address)
        }

        // MARK: - 7

        func test_scenario_sessionExpired_confirmFailsWithCheckoutExpired_andClearsCard() async throws {
            let id = "scn_expiry"
            // A short real timer (the coordinator's sleep is not injectable through `create`); the test
            // awaits the timer task itself instead of polling.
            let page = try await makePage(
                id: id, submit: [snapshot(id, .succeeded)], withKey: true, expiresIn: 0.6)
            let entry = try XCTUnwrap(page.card.newCardEntryForTest)
            entry.fillCardForTest()
            XCTAssertFalse(entry.panTextForTest.isEmpty, "precondition: a card is typed")
            XCTAssertEqual(page.elements.coordinator.state, .ready, "precondition: not expired yet")

            await page.elements.coordinator.expiryTask?.value

            XCTAssertEqual(page.elements.coordinator.state, .expired)
            XCTAssertEqual(entry.panTextForTest, "", "typed card cleared")
            XCTAssertFalse(page.card.isInteractiveForTest)
            XCTAssertEqual(page.expressButton?.isUserInteractionEnabled, false)
            let outcome = await page.elements.confirm()
            expectFailed(outcome, code: "CHECKOUT_EXPIRED")
            XCTAssertEqual(page.payment.submitCallCount, 0)
        }

        // MARK: - 8

        func test_scenario_hideCard_cardUnavailable_expressStillWorks() async throws {
            let id = "scn_hide_card"
            let page = try await makePage(
                id: id, cards: [usable], submit: [snapshot(id, .succeeded)],
                filter: PaymentMethodFilter(hide: ["CARD"]))

            XCTAssertFalse(page.card.isAvailable)
            XCTAssertEqual(page.card.view.intrinsicContentSize.height, 0)
            XCTAssertEqual(page.card.view.frame.height, 0, "zero-height in the laid-out page")
            XCTAssertTrue(page.express.isAvailable, "Apple Pay is unaffected")
            XCTAssertNotNil(page.expressButton)
            let outcome = await page.elements.confirm()
            expectFailed(outcome, code: "NO_PAYMENT_OPTION_SELECTED")
            XCTAssertEqual(page.payment.submitCallCount, 0)

            // The express path still pays on this page.
            let tapResult: CheckoutOutcome = await withCheckedContinuation { continuation in
                page.express.onResult = { continuation.resume(returning: $0) }
                page.express.simulateTap()
            }
            XCTAssertEqual(tapResult, .succeeded(txnId: "txn_1"))
            XCTAssertEqual(page.payment.submitCallCount, 1)
        }

        // MARK: - 9

        func test_scenario_closeThenConfirm_doesNotPay() async throws {
            let id = "scn_close"
            let page = try await makePage(id: id, cards: [usable], submit: [snapshot(id, .succeeded)])
            XCTAssertTrue(page.card.isComplete, "precondition: payable before close")

            page.elements.close()
            let outcome = await page.elements.confirm()

            XCTAssertEqual(outcome, .canceled)
            XCTAssertEqual(page.payment.submitCallCount, 0)
            XCTAssertFalse(page.card.isInteractiveForTest)
            XCTAssertEqual(page.expressButton?.isUserInteractionEnabled, false)
            var held = await page.credentials.current()
            let deadline = Date().addingTimeInterval(5)
            while held != nil, Date() < deadline {
                try await Task.sleep(nanoseconds: 10_000_000)
                held = await page.credentials.current()
            }
            XCTAssertNil(held)
        }
    }
#endif
