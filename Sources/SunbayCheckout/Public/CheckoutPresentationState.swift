import Foundation

/// The public, coarse-grained presentation state surfaced via `PaymentSheet.onStateChange` (spec §3.4).
///
/// This mirrors the internal `CheckoutViewState` without exposing its associated values: hosts observe
/// the high-level phase of the in-sheet flow (e.g. for analytics) but never drive it. Observing this
/// does not change the auto-close behavior.
public enum CheckoutPresentationState: Sendable {
    /// Choosing method / filling the form.
    case editing
    /// Confirm in flight.
    case processing
    /// Payment succeeded (the sheet is auto-closing).
    case succeeded
    /// Payment failed (the sheet stays open for retry).
    case failed
}
