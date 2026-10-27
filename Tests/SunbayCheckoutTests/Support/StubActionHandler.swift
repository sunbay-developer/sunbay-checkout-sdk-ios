import Foundation

@testable import SunbayCheckout

/// Scriptable test double for `ActionHandling` (the real Task 8 implementation has not landed yet).
///
/// Returns a scripted `ActionResult` and records whether it was called and the `action` / `sessionId`
/// it received. Defaults to returning `.pending` (matching the first-version redirect → pending behavior).
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
