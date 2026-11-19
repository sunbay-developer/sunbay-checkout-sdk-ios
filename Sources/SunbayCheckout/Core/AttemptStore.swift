import Foundation

/// Remembers, per session, the most recent submitted attempt and whether its result is still unsettled.
///
/// Every confirm mints a new `attemptId`, so the backend can no longer dedupe a repeated tap. After a confirm
/// ends `.pending` / `.unknown`, the next confirm for that session must first query that attempt (see
/// `CheckoutController`) instead of submitting blindly.
///
/// One store is owned by `SunbayCheckout` and shared by every controller it creates, so the marker survives
/// closing and re-presenting the sheet. Memory only: nothing is persisted across a process restart.
final class AttemptStore: @unchecked Sendable {
    private let lock = NSLock()
    private var last: [String: UUID] = [:]
    private var unsettled: Set<String> = []

    init() {}

    /// Records the attempt that is about to be submitted for `sessionId`.
    func record(sessionId: String, attemptId: UUID) {
        lock.lock(); defer { lock.unlock() }
        last[sessionId] = attemptId
    }

    /// The most recently submitted attempt for `sessionId`, if any.
    func lastAttemptId(sessionId: String) -> UUID? {
        lock.lock(); defer { lock.unlock() }
        return last[sessionId]
    }

    /// Marks the last attempt of `sessionId` as unsettled (`true`) or settled (`false`).
    func setUnsettled(_ value: Bool, sessionId: String) {
        lock.lock(); defer { lock.unlock() }
        if value { unsettled.insert(sessionId) } else { unsettled.remove(sessionId) }
    }

    /// Whether the last attempt of `sessionId` has an unconfirmed result.
    func isUnsettled(sessionId: String) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return unsettled.contains(sessionId)
    }
}
