import Foundation

/// The visible state of the checkout content (spec §3.1).
///
/// This is the internal state machine driven by the content view controller (Task 8). It is
/// deliberately UIKit-free so it compiles and runs under host `swift test`.
///
/// Field-level validation errors (card number / expiry / CVC) are NOT part of this machine; they
/// are `CardFormView`'s own internal state. `pending` / `unknown` are not visible states either:
/// on receiving them the content returns to `.editing` and shows a neutral info notice.
///
/// Transitions are one-way: `editing → processing → (succeeded | failed)`; `failed` and the
/// info notice can return to `editing` for retry; `succeeded` is terminal and triggers auto-close.
enum CheckoutViewState: Sendable, Equatable {
    /// Choosing method / filling the form; fully interactive.
    case editing
    /// Confirm in flight; form disabled, CTA spinner, dismissal blocked.
    case processing
    /// CTA ring→checkmark animation, then auto-close. Terminal.
    case succeeded
    /// Inline alert above the CTA; the sheet stays open and re-editable.
    case failed(reason: String)
}
