import Foundation

/// Tracks which sessions have an UNRESOLVED payment outcome (`.pending` / `.unknown`), so that any
/// controller sharing this store refuses to submit that session again until it has been reconciled
/// against the server (AGENTS.md hard rule 5: query first, never blindly resubmit).
///
/// ## Scope and lifetime
/// - Owned by ONE `SunbayCheckout` instance and handed to every `CheckoutController` it creates, so a
///   host that closes a `PaymentSheet` with `.unknown` and later builds a new `PaymentSheet` /
///   `ApplePayButton` from the same `SunbayCheckout` for the same session still honors the marker.
/// - Different `SunbayCheckout` instances do NOT share state (hosts should keep one instance per
///   app / session).
/// - MEMORY ONLY. Nothing is persisted (AGENTS.md §2.4): a process restart loses every marker, and
///   recovery after a restart is the host's `retrievePayment` (spec §4.3).
///
/// Holds session identifiers only; no card data, tokens, or secrets. Thread-safe via a lock, so it can
/// be called from the `CheckoutController` actor and from tests alike.
final class PendingReconciliationStore: @unchecked Sendable {
    private let lock = NSLock()
    private var sessionIds: Set<String> = []
    /// Per-session arm counter. Every `arm` bumps it, so a resolver that read the generation BEFORE an
    /// `await` can tell whether the marker was re-armed (by a newer attempt) while it was suspended.
    private var generations: [String: UInt64] = [:]

    init() {}

    /// Marks `sessionId` as having an unresolved outcome (and bumps its generation).
    func arm(_ sessionId: String) {
        lock.lock(); defer { lock.unlock() }
        sessionIds.insert(sessionId)
        generations[sessionId, default: 0] &+= 1
    }

    /// Clears the marker for `sessionId` unconditionally (terminal resolution by the attempt that owns the lock).
    func disarm(_ sessionId: String) {
        lock.lock(); defer { lock.unlock() }
        sessionIds.remove(sessionId)
    }

    /// The current arm generation of `sessionId` (0 if never armed).
    func generation(_ sessionId: String) -> UInt64 {
        lock.lock(); defer { lock.unlock() }
        return generations[sessionId] ?? 0
    }

    /// Clears the marker only if it has NOT been re-armed since `generation` was read, so an older
    /// verdict (obtained across an `await`) cannot clear a marker that a newer attempt just set.
    func disarm(_ sessionId: String, ifGeneration generation: UInt64) {
        lock.lock(); defer { lock.unlock() }
        guard (generations[sessionId] ?? 0) == generation else { return }
        sessionIds.remove(sessionId)
    }

    /// Whether `sessionId` currently has an unresolved outcome.
    func isArmed(_ sessionId: String) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return sessionIds.contains(sessionId)
    }
}
