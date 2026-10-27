import Foundation

/// Dispatch injection point (seam) for the `requiresAction` (R) action.
///
/// This is the protocol seam before Task 8 (`ActionHandler`) lands: `CheckoutController` depends
/// only on this protocol, and the real implementation (redirect → `ASWebAuthenticationSession`;
/// qrCode/showContent → UNSUPPORTED_CAPABILITY, see product-spec §4.5) is provided by Task 8, so
/// this task can land first. Tests use a scripted stand-in.
///
/// UI-agnostic: the protocol itself does not depend on any UIKit/PassKit types (Core constraint, see AGENTS.md §2.6).
protocol ActionHandling: Sendable {
    /// Handles a further action.
    ///
    /// - Parameters:
    ///   - action: The action carried by the backend in the `R` state (see `PaymentAction`).
    ///   - sessionId: The current session identifier.
    /// - Returns: The handling result: `.pending` (e.g. a redirect was opened, awaiting return/polling) or `.failed` (unsupported, etc.).
    func handle(_ action: PaymentAction, sessionId: String) async -> ActionResult
}

/// The result of `ActionHandling.handle`.
///
/// First-version semantics (§4.5): `redirect` → `.pending` after opening; `qrCode` / `showContent` / unknown →
/// `.failed(UNSUPPORTED_CAPABILITY)`. The controller maps this to a `CheckoutOutcome`.
enum ActionResult: Sendable {
    /// The action was triggered; the transaction is still processing (needs polling / return to confirm the terminal state).
    case pending
    /// The action cannot be handled (such as an unsupported capability).
    case failed(CheckoutError)
}
