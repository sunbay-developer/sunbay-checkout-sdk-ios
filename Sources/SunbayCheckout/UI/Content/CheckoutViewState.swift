import Foundation

/// The visible state of the checkout content (spec §3.1).
///
/// This is the internal state machine driven by the content view controller (Task 8). It is
/// deliberately UIKit-free so it compiles and runs under host `swift test`.
///
/// Field-level validation errors (card number / expiry / CVC) are NOT part of this machine; they
/// are `CardFormView`'s own internal state.
///
/// `pending` / `unknown` enter `.reconciling`: the payment outcome is not settled (the earlier attempt
/// may still succeed server-side), so the content stays locked and shows a "confirming your payment,
/// please don't try again" notice instead of returning to an interactive state. Core independently
/// refuses to resubmit until it has reconciled via `getResult` (see `CheckoutController`); this state
/// is the UI half of that same rule.
///
/// Transitions: `editing → processing → (succeeded | failed | reconciling)`; `failed` can return to
/// `editing` for retry; `reconciling` stays locked (only closing the sheet leaves it) until a NEW
/// outcome is applied; `succeeded` is terminal and triggers auto-close.
enum CheckoutViewState: Sendable, Equatable {
    /// Choosing method / filling the form; fully interactive.
    case editing
    /// Confirm in flight; form disabled, CTA spinner, dismissal blocked.
    case processing
    /// CTA ring→checkmark animation, then auto-close. Terminal.
    case succeeded
    /// Inline alert above the CTA; the sheet stays open and re-editable.
    case failed(reason: String)
    /// Outcome `pending` / `unknown`: payment not settled. Pay hidden, inputs locked, info notice shown;
    /// only the header ✕ stays available so the user can leave (the host then calls `retrievePayment()`).
    case reconciling
}

extension CheckoutViewState {
    /// Whether a new confirm / page navigation must be refused: a payment is in flight (`.processing`)
    /// or its outcome is unsettled and being reconciled (`.reconciling`).
    var isLockedAgainstNewConfirm: Bool {
        switch self {
        case .processing, .reconciling: return true
        case .editing, .succeeded, .failed: return false
        }
    }
}
