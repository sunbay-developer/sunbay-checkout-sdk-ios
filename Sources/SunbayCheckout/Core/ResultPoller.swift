import Foundation

/// Polling parameters (product-spec §4.4, configurable, to be fine-tuned once the backend is ready).
///
/// Durations use `TimeInterval` (seconds, `Double`) rather than `Duration`: `Duration` requires iOS 16+,
/// while this SDK targets a minimum of iOS 15 (see implementation-plan Global Constraints), so seconds are used throughout.
///
/// - `initial`: The first backoff interval (seconds).
/// - `max`: The backoff cap (seconds); exponential doubling does not exceed this value.
/// - `overallLimit`: The cumulative elapsed-time limit (seconds); once reached and still non-terminal → return the latest non-terminal snapshot
///   (the controller maps this to `.unknown`, §4.3 "reach the limit → unknown").
///
/// Defaults: `initial = 1s`, `max = 5s`, `overallLimit = 90s` (§4.4: initial 1s → back off to a max of 5s; overall limit ~90s).
struct PollConfig: Sendable, Equatable {
    /// The first backoff interval (seconds).
    var initial: TimeInterval
    /// The backoff cap (seconds).
    var max: TimeInterval
    /// The cumulative elapsed-time limit (seconds).
    var overallLimit: TimeInterval

    /// Creates polling parameters.
    ///
    /// - Parameters:
    ///   - initial: The first backoff interval (seconds).
    ///   - max: The backoff cap (seconds).
    ///   - overallLimit: The cumulative elapsed-time limit (seconds).
    init(initial: TimeInterval, max: TimeInterval, overallLimit: TimeInterval) {
        self.initial = initial
        self.max = max
        self.overallLimit = overallLimit
    }

    /// §4.4 default parameters: initial 1s → cap 5s; overall limit 90s.
    static let `default` = PollConfig(initial: 1, max: 5, overallLimit: 90)
}

/// Result poller (§4.4 / §4.3).
///
/// Repeatedly calls `service.getResult(sessionId:)`:
/// - Hits a terminal state (`.succeeded` / `.failed`) → returns that snapshot **immediately**;
/// - Non-terminal (`.initial` / `.requiresAction`) → waits with **exponential backoff** (doubling from `initial`, capped at `max`),
///   until the cumulative elapsed time reaches `overallLimit`, then returns the **latest non-terminal snapshot** (the controller maps this → `.unknown`).
///
/// ## Deterministic test seam
/// The wait is performed via an injected `sleep` closure (argument in seconds). Production defaults to `Task.sleep(nanoseconds:)`;
/// tests inject a "zero-wait + records duration" stand-in, making tests fast and deterministic and allowing assertions on the requested backoff ladder.
///
/// ## Handling of `getResult` throwing (decided and recorded)
/// A transient `getResult` error does **not** abort polling: it is treated as one non-terminal step (retry after backoff), until the limit is reached;
/// upon reaching the limit it returns the **latest non-terminal snapshot observed so far**. If no snapshot was ever successfully obtained (e.g. getResult keeps throwing),
/// it falls back to returning an `.initial` snapshot (non-terminal), which the controller maps to `.unknown` — it **never crashes**, and **never** treats a transient
/// network hiccup as a payment failure.
///
/// `actor`-isolated; imports no UIKit/PassKit (Core is UI-agnostic).
actor ResultPoller {
    private let service: any PaymentService
    private let config: PollConfig
    private let sleep: @Sendable (TimeInterval) async throws -> Void

    /// Creates a result poller.
    ///
    /// - Parameters:
    ///   - service: The backend payment capability (used for `getResult`).
    ///   - config: Polling parameters, defaults to `.default`.
    ///   - sleep: The wait implementation (injection seam, argument in seconds), defaults to `Task.sleep(nanoseconds:)`.
    init(
        service: any PaymentService,
        config: PollConfig = .default,
        sleep: @escaping @Sendable (TimeInterval) async throws -> Void = { seconds in
            try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
        }
    ) {
        self.service = service
        self.config = config
        self.sleep = sleep
    }

    /// Polls until a terminal state or the limit.
    ///
    /// - Parameter sessionId: Session identifier.
    /// - Returns: A terminal snapshot (`.succeeded` / `.failed`), or the latest non-terminal snapshot when the limit is reached.
    func pollUntilTerminal(sessionId: String) async -> PaymentSnapshot {
        // The latest non-terminal snapshot observed so far; falls back to .initial when no query has ever succeeded.
        var latestNonTerminal = PaymentSnapshot(sessionId: sessionId, status: .initial, txnId: nil)
        var elapsed: TimeInterval = 0
        var backoff = config.initial

        while true {
            // 1) Query the result once; a transient error does not abort, it is treated as one non-terminal step.
            if let snapshot = try? await service.getResult(sessionId: sessionId) {
                if isTerminal(snapshot.status) {
                    return snapshot
                }
                latestNonTerminal = snapshot
            }

            // 2) If one more backoff would exceed the limit, stop and return the latest non-terminal snapshot.
            if elapsed + backoff > config.overallLimit {
                return latestNonTerminal
            }

            // 3) Backoff wait (injected sleep); an error in the wait itself is not fatal, continue stepping.
            try? await sleep(backoff)
            elapsed += backoff

            // 4) Exponential backoff: double and cap at max.
            backoff = Swift.min(backoff * 2, config.max)
        }
    }

    /// Terminal-state check: `S` / `F` are terminal; `I` / `R` are non-terminal.
    private func isTerminal(_ status: TxnStatus) -> Bool {
        switch status {
        case .succeeded, .failed:
            return true
        case .initial, .requiresAction:
            return false
        }
    }
}
