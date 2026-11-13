import XCTest

@testable import SunbayCheckout

/// The presentation-independent checkout logic: loading the session context (filtering, COF, host
/// addresses) and dispatching a confirm. Runs headless on the macOS host.
final class CheckoutSessionDriverTests: XCTestCase {
    private struct StubWallet: WalletAuthorizing {
        func canMakePayments() -> Bool { false }
        func missingParameters(for params: ApplePayParams?) -> [String] { [] }
        func authorize(
            amount: Amount, merchantId: String, merchantName: String, params: ApplePayParams?,
            contacts: WalletContactRequest,
            confirm: @escaping @Sendable (WalletAuthorization) async -> CheckoutOutcome
        ) async throws -> CheckoutOutcome {
            throw CheckoutErrors.cardOnFileUnavailable()
        }
    }

    private final class Recorder: @unchecked Sendable {
        private let lock = NSLock()
        private var _calls: [(Bool, Bool)] = []
        func record(_ billing: Bool, _ shipping: Bool) {
            lock.lock(); defer { lock.unlock() }
            _calls.append((billing, shipping))
        }
        var calls: [(Bool, Bool)] {
            lock.lock(); defer { lock.unlock() }
            return _calls
        }
    }

    private let card = SavedCard(id: "pm_1", brand: "visa", last4: "4242", expMonth: 12, expYear: 2099)

    private func makeSession(
        id: String = "sess_1", cofEnabled: Bool = true, collectBilling: Bool = false
    ) -> CheckoutSession {
        CheckoutSession(
            id: id, amount: Amount(minorUnits: 999, currencyCode: "USD"), merchantName: "Acme",
            methods: [.card, .savedCard], expiresAt: Date().addingTimeInterval(600), rsaPublicKey: nil,
            cofEnabled: cofEnabled, collectBillingAddress: collectBilling)
    }

    private func makeDriver(
        session: CheckoutSession? = nil,
        secret: String? = "secret_abc",
        billing: AddressInput? = nil,
        filter: PaymentMethodFilter = PaymentMethodFilter(),
        options: DriverOptions = DriverOptions(),
        configure: (MockPaymentService, MockCofService) -> Void = { _, _ in }
    ) -> (CheckoutSessionDriver, MockPaymentService, MockCofService) {
        let payment = MockPaymentService()
        payment.stubSession(session ?? makeSession())
        let cof = MockCofService()
        cof.stubCards([card])
        configure(payment, cof)
        let controller = CheckoutController(
            paymentService: payment, cofService: cof, credentials: CredentialStore(),
            actionHandler: StubActionHandler(result: .pending))
        let driver = CheckoutSessionDriver(
            controller: controller, sessionId: (session ?? makeSession()).id, customerAccessSecret: secret,
            checkoutClientSecret: nil, billingAddress: billing, shippingAddress: nil, options: options,
            walletAuthorizer: StubWallet(), walletMerchantId: nil, paymentMethodFilter: filter)
        return (driver, payment, cof)
    }

    // MARK: - loadContext

    func test_loadContext_cofEffective_listsSavedCards() async {
        let (driver, _, cof) = makeDriver()
        guard case let .ready(context) = await driver.loadContext() else { return XCTFail("expected .ready") }
        XCTAssertEqual(context.savedCards, [card])
        XCTAssertTrue(context.cardOnFileEnabled)
        XCTAssertEqual(cof.listCallCount, 1)
    }

    func test_loadContext_noSecret_doesNotListCards() async {
        let (driver, _, cof) = makeDriver(secret: nil)
        guard case let .ready(context) = await driver.loadContext() else { return XCTFail("expected .ready") }
        XCTAssertEqual(context.savedCards, [])
        XCTAssertFalse(context.cardOnFileEnabled)
        XCTAssertEqual(cof.listCallCount, 0)
    }

    func test_loadContext_hideCardFilter_skipsListing_andFailsWithNoMethod() async {
        let (driver, _, cof) = makeDriver(filter: PaymentMethodFilter(hide: ["CARD"]))
        guard case let .startFailed(outcome) = await driver.loadContext(),
              case let .failed(_, error) = outcome else { return XCTFail("expected a start failure") }
        XCTAssertEqual(error.code, "NO_PAYMENT_METHOD_AVAILABLE")
        XCTAssertEqual(cof.listCallCount, 0)
    }

    func test_loadContext_noMethod_withFlagOff_returnsReadyWithEmptyEntries() async {
        let session = CheckoutSession(
            id: "sess_1", amount: Amount(minorUnits: 999, currencyCode: "USD"), merchantName: "Acme",
            methods: [.card], expiresAt: Date().addingTimeInterval(600), rsaPublicKey: nil,
            cofEnabled: true, collectBillingAddress: false)
        let (driver, payment, cof) = makeDriver(
            session: session, filter: PaymentMethodFilter(hide: ["CARD"]),
            options: DriverOptions(failsWhenNoMethodAvailable: false))
        guard case let .ready(context) = await driver.loadContext() else { return XCTFail("expected .ready") }
        XCTAssertTrue(context.visibleEntries.isEmpty)
        XCTAssertFalse(context.cardOnFileEnabled)
        XCTAssertEqual(context.savedCards, [])
        XCTAssertEqual(cof.listCallCount, 0)
        XCTAssertEqual(payment.loadSessionCallCount, 1)
    }

    func test_loadContext_sessionLoadCheckoutError_mapsToFailed() async {
        let expected = CheckoutErrors.networkUnavailable()
        let (driver, _, _) = makeDriver { payment, _ in payment.stubLoadError(expected) }
        guard case let .startFailed(outcome) = await driver.loadContext(),
              case let .failed(txnId, error) = outcome else { return XCTFail("expected .failed") }
        XCTAssertNil(txnId)
        XCTAssertEqual(error, expected)
    }

    func test_loadContext_sessionLoadOtherError_mapsToUnknown() async {
        let (driver, _, _) = makeDriver { payment, _ in payment.stubLoadError(URLError(.timedOut)) }
        guard case let .startFailed(outcome) = await driver.loadContext() else { return XCTFail("expected a start failure") }
        XCTAssertEqual(outcome, .unknown(sessionId: "sess_1"))
    }

    func test_loadContext_passesUsableEntryFlagsToAddressClosure() async {
        let recorder = Recorder()
        let options = DriverOptions(expressOff: false) { _, billingUsable, shippingUsable in
            recorder.record(billingUsable, shippingUsable)
            return (false, false)
        }
        let complete = AddressInput(country: "US", line1: "1 Main St", city: "NYC", postalCode: "10001")
        let (driver, _, _) = makeDriver(
            session: makeSession(collectBilling: true), billing: complete, options: options)
        guard case let .ready(context) = await driver.loadContext() else { return XCTFail("expected .ready") }
        XCTAssertTrue(context.billingEntryUsable)
        XCTAssertFalse(context.shippingEntryUsable)
        XCTAssertEqual(recorder.calls.count, 1)
        XCTAssertEqual(recorder.calls.first?.0, true)
        XCTAssertEqual(recorder.calls.first?.1, false)
    }

    // MARK: - execute

    func test_execute_cancel_returnsCanceled() async {
        let (driver, _, _) = makeDriver()
        _ = await driver.loadContext()
        let result = await driver.execute(.cancel)
        XCTAssertEqual(result, .outcome(.canceled))
    }

    func test_execute_confirmSavedCard_returnsControllerOutcome() async {
        let (driver, payment, _) = makeDriver { payment, _ in
            payment.stubSubmit([PaymentSnapshot(sessionId: "sess_1", status: .succeeded, txnId: "t1")])
        }
        _ = await driver.loadContext()
        let result = await driver.execute(.confirmSavedCard(paymentMethodId: "pm_1"))
        XCTAssertEqual(result, .outcome(.succeeded(txnId: "t1")))
        XCTAssertEqual(payment.submitCallCount, 1)
    }

    // MARK: - Close policy

    func test_outcomeOnClose_keepsUnsettledOutcomes_otherwiseCanceled() {
        XCTAssertEqual(CheckoutSessionDriver.outcomeOnClose(lastKnown: .pending(txnId: "t")), .pending(txnId: "t"))
        XCTAssertEqual(
            CheckoutSessionDriver.outcomeOnClose(lastKnown: .unknown(sessionId: "s")), .unknown(sessionId: "s"))
        XCTAssertEqual(CheckoutSessionDriver.outcomeOnClose(lastKnown: .succeeded(txnId: "t")), .canceled)
        XCTAssertEqual(CheckoutSessionDriver.outcomeOnClose(lastKnown: .canceled), .canceled)
        XCTAssertEqual(
            CheckoutSessionDriver.outcomeOnClose(
                lastKnown: .failed(txnId: nil, error: CheckoutErrors.networkUnavailable())),
            .canceled)
    }

    func test_isUnresolved_isTrueOnlyForPendingAndUnknown() {
        XCTAssertTrue(CheckoutSessionDriver.isUnresolved(.pending(txnId: nil)))
        XCTAssertTrue(CheckoutSessionDriver.isUnresolved(.unknown(sessionId: "s")))
        XCTAssertFalse(CheckoutSessionDriver.isUnresolved(.succeeded(txnId: "t")))
        XCTAssertFalse(CheckoutSessionDriver.isUnresolved(.canceled))
        XCTAssertFalse(
            CheckoutSessionDriver.isUnresolved(.failed(txnId: nil, error: CheckoutErrors.networkUnavailable())))
    }
}
