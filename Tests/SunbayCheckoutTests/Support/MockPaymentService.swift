import Foundation

@testable import SunbayCheckout

/// Scriptable test double for `PaymentService`.
///
/// Supports scripting return values or thrown errors separately for `loadSession` / `submit` / `getResult`,
/// and records call counts and the most recent `SubmitRequest`. Guards mutable state with `NSLock` to
/// satisfy `Sendable` (the actor coordinator reads/writes these counters outside its isolation domain, so
/// they must be thread-safe).
///
/// Optionally also implements `PaymentActionProviding`: when `submit` / `getResult` returns an `R`
/// (requiresAction) snapshot, the controller uses this to obtain the `PaymentAction` to dispatch to
/// `ActionHandling` (see the seam comments in CheckoutController).
final class MockPaymentService: PaymentService, PaymentActionProviding, @unchecked Sendable {
    private let lock = NSLock()

    // MARK: - Scripted inputs

    private var _session: CheckoutSession?
    private var _loadError: Error?

    /// Scripted snapshot sequence for `submit` (consumed in call order; once exhausted, the last one is reused).
    private var _submitSnapshots: [PaymentSnapshot] = []
    /// Error thrown by `submit` (when set, takes precedence over snapshots).
    private var _submitError: Error?
    /// Artificial delay before `submit` returns (for concurrency tests).
    private var _submitDelay: Duration?

    /// Scripted snapshot sequence for `getResult` (consumed in call order; once exhausted, the last one is reused).
    private var _getResultSnapshots: [PaymentSnapshot] = []
    /// Error thrown by `getResult`.
    private var _getResultError: Error?

    /// The further action corresponding to an `R` snapshot (seam: queried by the controller).
    private var _nextAction: PaymentAction?

    // MARK: - Observed outputs

    private(set) var submitCallCount = 0
    private(set) var getResultCallCount = 0
    private(set) var loadSessionCallCount = 0
    private(set) var lastSubmitRequest: SubmitRequest?

    init() {}

    // MARK: - Scripting API (called from the test thread)

    func stubSession(_ session: CheckoutSession) {
        lock.lock(); defer { lock.unlock() }
        _session = session
    }

    func stubLoadError(_ error: Error) {
        lock.lock(); defer { lock.unlock() }
        _loadError = error
    }

    func stubSubmit(_ snapshots: [PaymentSnapshot]) {
        lock.lock(); defer { lock.unlock() }
        _submitSnapshots = snapshots
    }

    func stubSubmitError(_ error: Error) {
        lock.lock(); defer { lock.unlock() }
        _submitError = error
    }

    func stubSubmitDelay(_ delay: Duration) {
        lock.lock(); defer { lock.unlock() }
        _submitDelay = delay
    }

    func stubGetResult(_ snapshots: [PaymentSnapshot]) {
        lock.lock(); defer { lock.unlock() }
        _getResultSnapshots = snapshots
    }

    func stubGetResultError(_ error: Error) {
        lock.lock(); defer { lock.unlock() }
        _getResultError = error
    }

    func stubNextAction(_ action: PaymentAction) {
        lock.lock(); defer { lock.unlock() }
        _nextAction = action
    }

    // MARK: - PaymentService

    func loadSession(_ id: String) async throws -> CheckoutSession {
        let (session, error): (CheckoutSession?, Error?) = {
            lock.lock(); defer { lock.unlock() }
            loadSessionCallCount += 1
            return (_session, _loadError)
        }()
        if let error { throw error }
        guard let session else {
            throw NSError(domain: "MockPaymentService", code: -1,
                          userInfo: [NSLocalizedDescriptionKey: "no stubbed session"])
        }
        return session
    }

    func submit(_ req: SubmitRequest) async throws -> PaymentSnapshot {
        let (delay, error, snapshot): (Duration?, Error?, PaymentSnapshot?) = {
            lock.lock(); defer { lock.unlock() }
            submitCallCount += 1
            lastSubmitRequest = req
            let snap: PaymentSnapshot?
            if _submitSnapshots.count > 1 {
                snap = _submitSnapshots.removeFirst()
            } else {
                snap = _submitSnapshots.first
            }
            return (_submitDelay, _submitError, snap)
        }()

        if let delay {
            try? await Task.sleep(for: delay)
        }
        if let error { throw error }
        guard let snapshot else {
            throw NSError(domain: "MockPaymentService", code: -2,
                          userInfo: [NSLocalizedDescriptionKey: "no stubbed submit snapshot"])
        }
        return snapshot
    }

    func getResult(sessionId: String) async throws -> PaymentSnapshot {
        let (error, snapshot): (Error?, PaymentSnapshot?) = {
            lock.lock(); defer { lock.unlock() }
            getResultCallCount += 1
            let snap: PaymentSnapshot?
            if _getResultSnapshots.count > 1 {
                snap = _getResultSnapshots.removeFirst()
            } else {
                snap = _getResultSnapshots.first
            }
            return (_getResultError, snap)
        }()

        if let error { throw error }
        guard let snapshot else {
            throw NSError(domain: "MockPaymentService", code: -3,
                          userInfo: [NSLocalizedDescriptionKey: "no stubbed getResult snapshot"])
        }
        return snapshot
    }

    // MARK: - PaymentActionProviding (seam)

    func actionForLatestRequiresAction() -> PaymentAction? {
        lock.lock(); defer { lock.unlock() }
        return _nextAction
    }
}
