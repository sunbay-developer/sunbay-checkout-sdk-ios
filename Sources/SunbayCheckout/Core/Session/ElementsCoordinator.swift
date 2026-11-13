import Foundation

/// Owns the single payment lock, outcome handling and session expiry shared by the Elements components.
///
/// `run` is the only place payment state transitions happen. It imports only Foundation (Core is
/// UI-agnostic), so it is testable on the host.
@MainActor
final class ElementsCoordinator {
    enum State: Equatable {
        case ready
        case confirming
        case finished(CheckoutOutcome)
        case expired
    }

    private let driver: CheckoutSessionDriver
    private let sleep: @Sendable (TimeInterval) async -> Void
    private let dismissAction: @Sendable () async -> Void
    private var didDismiss = false
    private var closed = false
    /// Expiry / close requested while `.confirming`; applied only once the in-flight body has returned
    /// so a real server outcome is never replaced by `expired` / `canceled`.
    private var pendingExpiry = false
    private var pendingClose = false
    /// The latest host-address update; `run` awaits it before the body so an update issued just before a
    /// confirm is always applied first.
    private var addressUpdate: Task<Void, Never>?

    let context: CheckoutSessionContext
    private(set) var state: State = .ready {
        didSet { if state != oldValue { onStateChange?(state) } }
    }
    var onStateChange: ((State) -> Void)?

    /// The pending expiry timer (internal so tests can await it).
    private(set) var expiryTask: Task<Void, Never>?

    /// - Parameter dismiss: Test seam for observing dismissal; defaults to `driver.dismiss()`.
    init(
        driver: CheckoutSessionDriver,
        context: CheckoutSessionContext,
        sleep: @escaping @Sendable (TimeInterval) async -> Void = {
            try? await Task.sleep(nanoseconds: ElementsCoordinator.sleepNanoseconds(for: $0))
        },
        dismiss: (@Sendable () async -> Void)? = nil
    ) {
        self.driver = driver
        self.context = context
        self.sleep = sleep
        self.dismissAction = dismiss ?? { await driver.dismiss() }
    }

    deinit { expiryTask?.cancel() }

    /// Upper bound for one expiry sleep (about 10 years). `expiresAt` is server data; an absurd value must
    /// not overflow the `UInt64` nanosecond conversion.
    static let maxSleepSeconds: TimeInterval = 315_360_000

    /// Nanoseconds to sleep for `seconds`, clamped to `0 ... maxSleepSeconds` (NaN counts as 0).
    static func sleepNanoseconds(for seconds: TimeInterval) -> UInt64 {
        guard seconds.isFinite || seconds == .infinity else { return 0 }
        return UInt64(min(max(0, seconds), maxSleepSeconds) * 1_000_000_000)
    }

    // MARK: - Run

    func run(_ body: () async -> CheckoutOutcome) async -> CheckoutOutcome {
        switch state {
        case .confirming:
            return .failed(txnId: nil, error: CheckoutErrors.alreadyPresenting())
        case let .finished(outcome):
            return outcome
        case .expired:
            return .failed(txnId: nil, error: CheckoutErrors.sessionExpired())
        case .ready:
            break
        }
        state = .confirming
        await addressUpdate?.value
        let outcome = await body()
        switch outcome {
        case .succeeded:
            state = .finished(outcome)
            await dismissOnce()
        case .pending, .unknown:
            state = .finished(outcome)
            // A close requested mid-flight still ends the session (clears secrets) once the body returns.
            if pendingClose { await dismissOnce() }
        case .failed, .canceled:
            if pendingClose {
                state = .finished(.canceled)
                await dismissOnce()
            } else if pendingExpiry {
                state = .expired
                await dismissOnce()
            } else {
                state = .ready
            }
        }
        pendingExpiry = false
        pendingClose = false
        return outcome
    }

    /// Queues a host-address update (ordered after any earlier one); the next `run` waits for it.
    func updateHostAddresses(billing: AddressInput?, shipping: AddressInput?) {
        let driver = driver
        let previous = addressUpdate
        addressUpdate = Task {
            await previous?.value
            await driver.updateHostAddresses(billing: billing, shipping: shipping)
        }
    }

    func perform(_ action: CheckoutUserAction) async -> CheckoutOutcome {
        await run {
            switch await driver.execute(action) {
            case let .outcome(outcome), let .startFailed(outcome): return outcome
            }
        }
    }

    // MARK: - Expiry / close

    func startExpiryTimer() {
        guard !closed else { return }
        switch state {
        case .ready, .confirming: break
        case .finished, .expired: return
        }
        expiryTask?.cancel()
        let delay = context.session.expiresAt.timeIntervalSinceNow
        let sleep = self.sleep
        expiryTask = Task { @MainActor [weak self] in
            await sleep(delay)
            guard !Task.isCancelled, let self else { return }
            await self.expire()
        }
    }

    private func expire() async {
        switch state {
        case .ready:
            state = .expired
            await dismissOnce()
        case .confirming:
            pendingExpiry = true
        case .finished, .expired:
            break
        }
    }

    /// The synchronous half of `close()`: blocks new payments at once (state / flags). Returns whether
    /// the caller should now `finishClose()` (false while a payment is in flight or when already closed;
    /// `run` dismisses in the former case).
    @discardableResult
    func requestClose() -> Bool {
        guard !closed else { return false }
        closed = true
        expiryTask?.cancel()
        switch state {
        case .confirming:
            pendingClose = true
            return false
        case .ready:
            state = .finished(.canceled)
        case .finished, .expired:
            break
        }
        return true
    }

    /// The asynchronous half of `close()`: dismisses the controller (once).
    func finishClose() async {
        await dismissOnce()
    }

    func close() async {
        if requestClose() { await finishClose() }
    }

    private func dismissOnce() async {
        guard !didDismiss else { return }
        didDismiss = true
        await dismissAction()
    }
}
