import Foundation

/// Pure-logic driver for the visible checkout state (spec §3.1 / §3.2).
///
/// The content view controller (Task 8) owns an instance of this machine: it calls `beginProcessing()`
/// when a confirm starts and `apply(_:localizedFailure:)` when a `CheckoutOutcome` comes back, then acts
/// on the returned `StepResult`. The machine never touches UIKit, Core, or the network, so it compiles
/// and runs under host `swift test`.
struct CheckoutStateMachine {
    /// What the caller should do after applying an outcome.
    enum StepResult: Equatable {
        /// Terminal success: animate, then auto-close returning this outcome.
        case autoClose(CheckoutOutcome)
        /// Show an inline error block with this localized reason; stay open for retry.
        case showError(String)
        /// Show a neutral "confirming your payment" notice (`pending` / `unknown`) and stay LOCKED in
        /// `.reconciling` (no Pay, no inputs); no auto-close.
        case showInfoNotice
        /// No visible change (e.g. `canceled`); let the caller handle dismissal.
        case stay
    }

    /// The current visible state. Starts at `.editing`.
    private(set) var state: CheckoutViewState = .editing

    /// Creates a state machine in the initial `.editing` state.
    init() {}

    /// Moves to `.processing` when a confirm is dispatched.
    mutating func beginProcessing() {
        state = .processing
    }

    /// Applies a confirm outcome, updates `state` per spec §3.2, and tells the caller how to react.
    ///
    /// - Parameters:
    ///   - outcome: The terminal / intermediate result from the confirm dispatch.
    ///   - localizedFailure: Maps a `CheckoutError` to a user-facing, localized message for the
    ///     `.failed` state (so this type stays free of any localization dependency).
    /// - Returns: The `StepResult` describing the next action.
    mutating func apply(
        _ outcome: CheckoutOutcome,
        localizedFailure: (CheckoutError) -> String
    ) -> StepResult {
        switch outcome {
        case let .succeeded(txnId):
            state = .succeeded
            return .autoClose(.succeeded(txnId: txnId))

        case let .failed(_, error):
            let reason = localizedFailure(error)
            state = .failed(reason: reason)
            return .showError(reason)

        case .pending, .unknown:
            // Not settled: lock (never return to an interactive state), a resubmit could double-charge.
            state = .reconciling
            return .showInfoNotice

        case .canceled:
            return .stay
        }
    }

    /// The public, coarse-grained mapping of `state` for `PaymentSheet.onStateChange`.
    var presentationState: CheckoutPresentationState {
        switch state {
        case .editing: return .editing
        case .processing: return .processing
        case .succeeded: return .succeeded
        case .failed: return .failed
        // No new public case (additive-only API): hosts keep seeing `.editing` for pending/unknown.
        case .reconciling: return .editing
        }
    }
}
