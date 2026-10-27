import Foundation

import SunbayCheckout

/// Scriptable, public-API-only double for `PaymentService`.
///
/// Shared by the e2e test target and the Example app. It mirrors the scripting semantics of the
/// test-internal `MockPaymentService`, but conforms ONLY to the public `PaymentService` protocol
/// (it does NOT conform to the internal `PaymentActionProviding` seam; requiresAction action
/// injection is handled elsewhere via `@testable`).
///
/// Supports scripting return values or thrown errors separately for `loadSession` / `submit` /
/// `getResult`, and records call counts and the most recent `SubmitRequest`. Mutable state is guarded
/// with `NSLock` to satisfy `Sendable` (callers may read/write these counters off the coordinator's
/// isolation domain, so they must be thread-safe).
public final class ScriptablePaymentService: PaymentService, @unchecked Sendable {
    private let lock = NSLock()

    // MARK: - Scripted inputs

    private var _session: CheckoutSession?
    private var _loadError: Error?

    /// Scripted snapshot sequence for `submit` (consumed in call order; once exhausted, the last one is reused).
    private var _submitSnapshots: [PaymentSnapshot] = []
    /// Error thrown by `submit` (when set, takes precedence over snapshots).
    private var _submitError: Error?
    /// Artificial delay (in seconds) before `submit` returns (for concurrency tests).
    ///
    /// Uses `TimeInterval` (seconds) rather than `Duration`: `Duration` requires iOS 16 / macOS 13,
    /// while this target must also build on the macOS host at the package's iOS-15-mapped deployment
    /// target. This mirrors the SDK's own convention (see `ResultPoller`).
    private var _submitDelay: TimeInterval?

    /// Scripted snapshot sequence for `getResult` (consumed in call order; once exhausted, the last one is reused).
    private var _getResultSnapshots: [PaymentSnapshot] = []
    /// Error thrown by `getResult`.
    private var _getResultError: Error?

    // MARK: - Observed outputs

    private var _submitCallCount = 0
    private var _getResultCallCount = 0
    private var _loadSessionCallCount = 0
    private var _lastSubmitRequest: SubmitRequest?

    public var submitCallCount: Int {
        lock.lock(); defer { lock.unlock() }
        return _submitCallCount
    }

    public var getResultCallCount: Int {
        lock.lock(); defer { lock.unlock() }
        return _getResultCallCount
    }

    public var loadSessionCallCount: Int {
        lock.lock(); defer { lock.unlock() }
        return _loadSessionCallCount
    }

    public var lastSubmitRequest: SubmitRequest? {
        lock.lock(); defer { lock.unlock() }
        return _lastSubmitRequest
    }

    public init() {}

    // MARK: - Scripting API (called from the test / demo thread)

    public func stubSession(_ session: CheckoutSession) {
        lock.lock(); defer { lock.unlock() }
        _session = session
    }

    public func stubLoadError(_ error: Error) {
        lock.lock(); defer { lock.unlock() }
        _loadError = error
    }

    public func stubSubmit(_ snapshots: [PaymentSnapshot]) {
        lock.lock(); defer { lock.unlock() }
        _submitSnapshots = snapshots
    }

    public func stubSubmitError(_ error: Error) {
        lock.lock(); defer { lock.unlock() }
        _submitError = error
    }

    public func stubSubmitDelay(_ delay: TimeInterval) {
        lock.lock(); defer { lock.unlock() }
        _submitDelay = delay
    }

    public func stubGetResult(_ snapshots: [PaymentSnapshot]) {
        lock.lock(); defer { lock.unlock() }
        _getResultSnapshots = snapshots
    }

    public func stubGetResultError(_ error: Error) {
        lock.lock(); defer { lock.unlock() }
        _getResultError = error
    }

    // MARK: - PaymentService

    public func loadSession(_ id: String) async throws -> CheckoutSession {
        let (session, error): (CheckoutSession?, Error?) = {
            lock.lock(); defer { lock.unlock() }
            _loadSessionCallCount += 1
            return (_session, _loadError)
        }()
        if let error { throw error }
        guard let session else {
            throw NSError(domain: "ScriptablePaymentService", code: -1,
                          userInfo: [NSLocalizedDescriptionKey: "no stubbed session"])
        }
        return session
    }

    public func submit(_ req: SubmitRequest) async throws -> PaymentSnapshot {
        let (delay, error, snapshot): (TimeInterval?, Error?, PaymentSnapshot?) = {
            lock.lock(); defer { lock.unlock() }
            _submitCallCount += 1
            _lastSubmitRequest = req
            let snap: PaymentSnapshot?
            if _submitSnapshots.count > 1 {
                snap = _submitSnapshots.removeFirst()
            } else {
                snap = _submitSnapshots.first
            }
            return (_submitDelay, _submitError, snap)
        }()

        if let delay {
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
        }
        if let error { throw error }
        guard let snapshot else {
            throw NSError(domain: "ScriptablePaymentService", code: -2,
                          userInfo: [NSLocalizedDescriptionKey: "no stubbed submit snapshot"])
        }
        return snapshot
    }

    public func getResult(sessionId: String) async throws -> PaymentSnapshot {
        let (error, snapshot): (Error?, PaymentSnapshot?) = {
            lock.lock(); defer { lock.unlock() }
            _getResultCallCount += 1
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
            throw NSError(domain: "ScriptablePaymentService", code: -3,
                          userInfo: [NSLocalizedDescriptionKey: "no stubbed getResult snapshot"])
        }
        return snapshot
    }
}
