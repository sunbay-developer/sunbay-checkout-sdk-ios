import Foundation

@testable import SunbayCheckout

/// 可脚本化的 `PaymentService` 测试替身。
///
/// 支持为 `loadSession` / `submit` / `getResult` 分别脚本化返回值或抛出的错误,
/// 并记录调用次数与最近一次 `SubmitRequest`。用 `NSLock` 保护可变状态,满足 `Sendable`
/// (actor 协调器会在隔离域外读写这些计数,必须线程安全)。
///
/// 另外可选地实现 `PaymentActionProviding`:当 `submit` / `getResult` 返回 `R`
/// (requiresAction)快照时,控制器据此获取要分发给 `ActionHandling` 的 `PaymentAction`
/// (见 CheckoutController 的 seam 注释)。
final class MockPaymentService: PaymentService, PaymentActionProviding, @unchecked Sendable {
    private let lock = NSLock()

    // MARK: - 脚本化输入

    private var _session: CheckoutSession?
    private var _loadError: Error?

    /// `submit` 的脚本化快照序列(按调用顺序消费;耗尽后复用最后一个)。
    private var _submitSnapshots: [PaymentSnapshot] = []
    /// `submit` 抛出的错误(设置后优先于快照)。
    private var _submitError: Error?
    /// `submit` 返回前的人为延迟(用于并发测试)。
    private var _submitDelay: Duration?

    /// `getResult` 的脚本化快照序列(按调用顺序消费;耗尽后复用最后一个)。
    private var _getResultSnapshots: [PaymentSnapshot] = []
    /// `getResult` 抛出的错误。
    private var _getResultError: Error?

    /// `R` 快照对应的进一步动作(seam:供控制器查询)。
    private var _nextAction: PaymentAction?

    // MARK: - 观测输出

    private(set) var submitCallCount = 0
    private(set) var getResultCallCount = 0
    private(set) var loadSessionCallCount = 0
    private(set) var lastSubmitRequest: SubmitRequest?

    init() {}

    // MARK: - 脚本化 API(测试线程调用)

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

    // MARK: - PaymentActionProviding(seam)

    func actionForLatestRequiresAction() -> PaymentAction? {
        lock.lock(); defer { lock.unlock() }
        return _nextAction
    }
}
