import XCTest

@testable import SunbayCheckout

/// The shared payment lock / outcome handling / expiry owner behind the Elements components.
/// Runs headless on the macOS host (the coordinator imports only Foundation).
@MainActor
final class ElementsCoordinatorTests: XCTestCase {
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

    private final class Counter: @unchecked Sendable {
        private let lock = NSLock()
        private var _value = 0
        func increment() { lock.lock(); _value += 1; lock.unlock() }
        var value: Int { lock.lock(); defer { lock.unlock() }; return _value }
    }

    private final class States: @unchecked Sendable {
        var values: [ElementsCoordinator.State] = []
    }

    private let card = SavedCard(id: "pm_1", brand: "visa", last4: "4242", expMonth: 12, expYear: 2099)
    private let saved = CheckoutUserAction.confirmSavedCard(paymentMethodId: "pm_1")

    private func makeCoordinator(
        sleep: @escaping @Sendable (TimeInterval) async -> Void = { _ in try? await Task.sleep(nanoseconds: 10_000_000_000) },
        dismissCounter: Counter = Counter(),
        configure: (MockPaymentService) -> Void = { _ in }
    ) async -> (ElementsCoordinator, MockPaymentService, Counter) {
        let session = CheckoutSession(
            id: "sess_1", amount: Amount(minorUnits: 999, currencyCode: "USD"), merchantName: "Acme",
            methods: [.card, .savedCard], expiresAt: Date().addingTimeInterval(600), rsaPublicKey: nil,
            cofEnabled: true, collectBillingAddress: false)
        let payment = MockPaymentService()
        payment.stubSession(session)
        let cof = MockCofService()
        cof.stubCards([card])
        configure(payment)
        let controller = CheckoutController(
            paymentService: payment, cofService: cof, credentials: CredentialStore(),
            actionHandler: StubActionHandler(result: .pending))
        let driver = CheckoutSessionDriver(
            controller: controller, sessionId: "sess_1", customerAccessSecret: "secret_abc",
            checkoutClientSecret: nil, billingAddress: nil, shippingAddress: nil,
            options: DriverOptions(failsWhenNoMethodAvailable: false),
            walletAuthorizer: StubWallet(), walletMerchantId: nil, paymentMethodFilter: PaymentMethodFilter())
        guard case let .ready(context) = await driver.loadContext() else {
            XCTFail("expected .ready")
            fatalError("context not ready")
        }
        let coordinator = ElementsCoordinator(
            driver: driver, context: context, sleep: sleep,
            dismiss: { dismissCounter.increment() })
        return (coordinator, payment, dismissCounter)
    }

    private func succeededSnapshot() -> PaymentSnapshot {
        PaymentSnapshot(sessionId: "sess_1", status: .succeeded, txnId: "t1")
    }

    private func failedSnapshot() -> PaymentSnapshot {
        PaymentSnapshot(sessionId: "sess_1", status: .failed, txnId: "t0")
    }

    // MARK: - perform

    func test_perform_savedCard_succeeded_finishesAndDismisses() async {
        let (coordinator, _, dismissals) = await makeCoordinator { $0.stubSubmit([self.succeededSnapshot()]) }
        let outcome = await coordinator.perform(saved)
        XCTAssertEqual(outcome, .succeeded(txnId: "t1"))
        XCTAssertEqual(coordinator.state, .finished(.succeeded(txnId: "t1")))
        XCTAssertEqual(dismissals.value, 1)
    }

    func test_perform_failed_returnsToReady_andAllowsRetry() async {
        let (coordinator, payment, _) = await makeCoordinator { $0.stubSubmit([self.failedSnapshot()]) }
        let first = await coordinator.perform(saved)
        guard case .failed = first else { return XCTFail("expected .failed, got \(first)") }
        XCTAssertEqual(coordinator.state, .ready)
        _ = await coordinator.perform(saved)
        XCTAssertEqual(payment.submitCallCount, 2)
    }

    func test_perform_pending_locksAndReturnsStoredOutcome_withoutResubmit() async {
        let (coordinator, payment, _) = await makeCoordinator {
            $0.stubSubmit([PaymentSnapshot(sessionId: "sess_1", status: .initial, txnId: "t1")])
        }
        let first = await coordinator.perform(saved)
        guard case .pending = first else { return XCTFail("expected .pending, got \(first)") }
        let second = await coordinator.perform(saved)
        XCTAssertEqual(second, first)
        XCTAssertEqual(payment.submitCallCount, 1)
        XCTAssertEqual(coordinator.state, .finished(first))
    }

    func test_perform_unknown_locks() async {
        let (coordinator, payment, _) = await makeCoordinator {
            $0.stubSubmitError(URLError(.timedOut))
            $0.stubGetResultError(URLError(.timedOut))
        }
        let first = await coordinator.perform(saved)
        guard case .unknown = first else { return XCTFail("expected .unknown, got \(first)") }
        let submits = payment.submitCallCount
        let second = await coordinator.perform(saved)
        XCTAssertEqual(second, first)
        XCTAssertEqual(payment.submitCallCount, submits)
        XCTAssertEqual(coordinator.state, .finished(first))
    }

    // MARK: - run

    func test_secondRunWhileConfirming_returnsAlreadyPresenting() async {
        let (coordinator, _, _) = await makeCoordinator()
        var release: CheckedContinuation<Void, Never>?
        let entered = expectation(description: "body entered")
        let firstTask = Task { @MainActor in
            await coordinator.run {
                await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
                    release = c
                    entered.fulfill()
                }
                return .canceled
            }
        }
        await fulfillment(of: [entered], timeout: 5)
        XCTAssertEqual(coordinator.state, .confirming)
        let second = await coordinator.run { .succeeded(txnId: "never") }
        XCTAssertEqual(second, .failed(txnId: nil, error: CheckoutErrors.alreadyPresenting()))
        release?.resume()
        let first = await firstTask.value
        XCTAssertEqual(first, .canceled)
        XCTAssertEqual(coordinator.state, .ready)
    }

    func test_afterSucceeded_runReturnsSucceededWithoutBody() async {
        let (coordinator, _, _) = await makeCoordinator()
        _ = await coordinator.run { .succeeded(txnId: "t9") }
        let bodyCalls = Counter()
        let outcome = await coordinator.run { bodyCalls.increment(); return .canceled }
        XCTAssertEqual(outcome, .succeeded(txnId: "t9"))
        XCTAssertEqual(bodyCalls.value, 0)
    }

    func test_canceled_behavesLikeFailed() async {
        let (coordinator, _, _) = await makeCoordinator()
        let outcome = await coordinator.run { .canceled }
        XCTAssertEqual(outcome, .canceled)
        XCTAssertEqual(coordinator.state, .ready)
    }

    // MARK: - expiry

    func test_expiry_whenTimerFires_marksExpired_andRunReturnsCheckoutExpired() async {
        let (coordinator, _, dismissals) = await makeCoordinator(sleep: { _ in })
        coordinator.startExpiryTimer()
        await coordinator.expiryTask?.value
        XCTAssertEqual(coordinator.state, .expired)
        XCTAssertEqual(dismissals.value, 1)
        let bodyCalls = Counter()
        let outcome = await coordinator.run { bodyCalls.increment(); return .succeeded(txnId: "x") }
        XCTAssertEqual(outcome, .failed(txnId: nil, error: CheckoutErrors.sessionExpired()))
        XCTAssertEqual(bodyCalls.value, 0)
    }

    func test_expiry_doesNotOverrideFinishedState() async {
        let (coordinator, _, dismissals) = await makeCoordinator(sleep: { _ in })
        _ = await coordinator.run { .succeeded(txnId: "t1") }
        coordinator.startExpiryTimer()
        await coordinator.expiryTask?.value
        XCTAssertEqual(coordinator.state, .finished(.succeeded(txnId: "t1")))
        XCTAssertEqual(dismissals.value, 1)
    }

    // MARK: - close

    func test_close_dismissesOnce_andIsIdempotent() async {
        let (coordinator, _, dismissals) = await makeCoordinator()
        await coordinator.close()
        await coordinator.close()
        XCTAssertEqual(dismissals.value, 1)
        XCTAssertEqual(coordinator.state, .finished(.canceled))
    }

    func test_close_afterSuccess_doesNotDismissAgain_orChangeState() async {
        let (coordinator, _, dismissals) = await makeCoordinator()
        _ = await coordinator.run { .succeeded(txnId: "t1") }
        await coordinator.close()
        XCTAssertEqual(dismissals.value, 1)
        XCTAssertEqual(coordinator.state, .finished(.succeeded(txnId: "t1")))
    }

    // MARK: - expiry / close during a suspended body

    /// Starts `run` with a body suspended until `release` is called, then invokes `during`, then resumes the
    /// body with `result`. Returns the outcome of the first run.
    private func runWithSuspendedBody(
        _ coordinator: ElementsCoordinator, result: CheckoutOutcome,
        during: () async -> Void
    ) async -> CheckoutOutcome {
        var release: CheckedContinuation<Void, Never>?
        let entered = expectation(description: "body entered")
        let task = Task { @MainActor in
            await coordinator.run {
                await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
                    release = c
                    entered.fulfill()
                }
                return result
            }
        }
        await fulfillment(of: [entered], timeout: 5)
        await during()
        XCTAssertEqual(coordinator.state, .confirming)
        release?.resume()
        return await task.value
    }

    func test_expiryDuringConfirming_succeeded_keepsSucceeded() async {
        let (coordinator, _, dismissals) = await makeCoordinator(sleep: { _ in })
        let outcome = await runWithSuspendedBody(coordinator, result: .succeeded(txnId: "t1")) {
            coordinator.startExpiryTimer()
            await coordinator.expiryTask?.value
        }
        XCTAssertEqual(outcome, .succeeded(txnId: "t1"))
        XCTAssertEqual(coordinator.state, .finished(.succeeded(txnId: "t1")))
        XCTAssertEqual(dismissals.value, 1)
        let again = await coordinator.run { .canceled }
        XCTAssertEqual(again, .succeeded(txnId: "t1"))
    }

    func test_expiryDuringConfirming_pending_locksPending() async {
        let (coordinator, _, _) = await makeCoordinator(sleep: { _ in })
        let pending = CheckoutOutcome.pending(txnId: "t1")
        let outcome = await runWithSuspendedBody(coordinator, result: pending) {
            coordinator.startExpiryTimer()
            await coordinator.expiryTask?.value
        }
        XCTAssertEqual(outcome, pending)
        XCTAssertEqual(coordinator.state, .finished(pending))
        let again = await coordinator.run { .canceled }
        XCTAssertEqual(again, pending)
    }

    func test_expiryDuringConfirming_failed_appliesDeferredExpiry() async {
        let (coordinator, _, dismissals) = await makeCoordinator(sleep: { _ in })
        let failed = CheckoutOutcome.failed(txnId: nil, error: CheckoutErrors.networkUnavailable())
        let outcome = await runWithSuspendedBody(coordinator, result: failed) {
            coordinator.startExpiryTimer()
            await coordinator.expiryTask?.value
            XCTAssertEqual(dismissals.value, 0)
        }
        XCTAssertEqual(outcome, failed)
        XCTAssertEqual(coordinator.state, .expired)
        XCTAssertEqual(dismissals.value, 1)
        let again = await coordinator.run { .succeeded(txnId: "x") }
        XCTAssertEqual(again, .failed(txnId: nil, error: CheckoutErrors.sessionExpired()))
    }

    func test_closeDuringConfirming_succeeded_keepsSucceeded() async {
        let (coordinator, _, dismissals) = await makeCoordinator()
        let outcome = await runWithSuspendedBody(coordinator, result: .succeeded(txnId: "t1")) {
            await coordinator.close()
        }
        XCTAssertEqual(outcome, .succeeded(txnId: "t1"))
        XCTAssertEqual(coordinator.state, .finished(.succeeded(txnId: "t1")))
        XCTAssertEqual(dismissals.value, 1)
    }

    func test_closeDuringConfirming_failed_becomesCanceled() async {
        let (coordinator, _, dismissals) = await makeCoordinator()
        let failed = CheckoutOutcome.failed(txnId: nil, error: CheckoutErrors.networkUnavailable())
        let outcome = await runWithSuspendedBody(coordinator, result: failed) {
            await coordinator.close()
            XCTAssertEqual(dismissals.value, 0)
        }
        XCTAssertEqual(outcome, failed)
        XCTAssertEqual(coordinator.state, .finished(.canceled))
        XCTAssertEqual(dismissals.value, 1)
    }

    /// A deferred close must still dismiss (clear secrets) when the in-flight attempt ends unsettled.
    func test_closeDuringConfirming_pendingOrUnknown_dismissesOnce() async {
        for settled in [CheckoutOutcome.pending(txnId: "t1"), .unknown(sessionId: "sess_1")] {
            let (coordinator, _, dismissals) = await makeCoordinator()
            let outcome = await runWithSuspendedBody(coordinator, result: settled) {
                await coordinator.close()
                XCTAssertEqual(dismissals.value, 0)
            }
            XCTAssertEqual(outcome, settled)
            XCTAssertEqual(coordinator.state, .finished(settled))
            XCTAssertEqual(dismissals.value, 1)
            await coordinator.close()
            XCTAssertEqual(dismissals.value, 1)
        }
    }

    func test_startExpiryTimer_afterClose_doesNotStart() async {
        let (coordinator, _, _) = await makeCoordinator(sleep: { _ in })
        await coordinator.close()
        coordinator.startExpiryTimer()
        XCTAssertNil(coordinator.expiryTask)
    }

    // MARK: - onStateChange

    func test_onStateChange_reportsTransitions() async {
        let (coordinator, _, _) = await makeCoordinator()
        let states = States()
        coordinator.onStateChange = { states.values.append($0) }
        _ = await coordinator.run { .failed(txnId: nil, error: CheckoutErrors.networkUnavailable()) }
        _ = await coordinator.run { .succeeded(txnId: "t1") }
        XCTAssertEqual(
            states.values,
            [.confirming, .ready, .confirming, .finished(.succeeded(txnId: "t1"))])
    }

    // MARK: - Final review fixes

    func test_defaultSleep_hugeDelay_doesNotTrap() async {
        let session = CheckoutSession(
            id: "sess_1", amount: Amount(minorUnits: 999, currencyCode: "USD"), merchantName: "Acme",
            methods: [.card], expiresAt: Date().addingTimeInterval(1e15), rsaPublicKey: nil,
            cofEnabled: false, collectBillingAddress: false)
        let payment = MockPaymentService()
        payment.stubSession(session)
        let controller = CheckoutController(
            paymentService: payment, cofService: MockCofService(), credentials: CredentialStore(),
            actionHandler: StubActionHandler(result: .pending))
        let driver = CheckoutSessionDriver(
            controller: controller, sessionId: "sess_1", customerAccessSecret: nil,
            checkoutClientSecret: nil, billingAddress: nil, shippingAddress: nil,
            options: DriverOptions(failsWhenNoMethodAvailable: false),
            walletAuthorizer: StubWallet(), walletMerchantId: nil, paymentMethodFilter: PaymentMethodFilter())
        guard case let .ready(context) = await driver.loadContext() else { return XCTFail("expected .ready") }
        let coordinator = ElementsCoordinator(driver: driver, context: context)  // default sleep
        coordinator.startExpiryTimer()  // must not trap
        await coordinator.close()
        XCTAssertEqual(ElementsCoordinator.sleepNanoseconds(for: 1e15), UInt64(ElementsCoordinator.maxSleepSeconds * 1e9))
        XCTAssertEqual(ElementsCoordinator.sleepNanoseconds(for: -5), 0)
    }
}
