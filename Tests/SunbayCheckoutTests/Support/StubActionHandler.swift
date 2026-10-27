import Foundation

@testable import SunbayCheckout

/// 可脚本化的 `ActionHandling` 测试替身(Task 8 的真实实现尚未落地)。
///
/// 返回脚本化的 `ActionResult`,并记录是否被调用及收到的 `action` / `sessionId`。
/// 默认返回 `.pending`(对应首版 redirect → pending 的行为)。
final class StubActionHandler: ActionHandling, @unchecked Sendable {
    private let lock = NSLock()

    private var _result: ActionResult = .pending

    private(set) var handleCallCount = 0
    private(set) var lastAction: PaymentAction?
    private(set) var lastSessionId: String?

    init(result: ActionResult = .pending) {
        _result = result
    }

    func stubResult(_ result: ActionResult) {
        lock.lock(); defer { lock.unlock() }
        _result = result
    }

    func handle(_ action: PaymentAction, sessionId: String) async -> ActionResult {
        lock.withLock {
            handleCallCount += 1
            lastAction = action
            lastSessionId = sessionId
            return _result
        }
    }
}
