import Foundation

/// Injection seam for opening a web authentication session.
///
/// Wraps the system `ASWebAuthenticationSession`: the real implementation is provided by Task 11
/// (`UI/Wallet/WebAuthOpener.swift`); this task only defines the protocol, and tests inject a stand-in.
///
/// Decoupling via a protocol keeps `ActionHandler` Core-pure (UI-agnostic, see AGENTS.md §2.6):
/// this file does **not** import AuthenticationServices / UIKit.
protocol WebAuthOpening: Sendable {
    /// Opens a payment web page for a third-party APM redirect (with a returnUrl for the return trip).
    ///
    /// - Parameter url: The redirect address issued by the backend in the `redirect` action.
    func open(_ url: URL) async
}

/// The first concrete implementation of `ActionHandling`: dispatches by `PaymentAction` type (see product-spec §4.5).
///
/// Semantics:
/// - `redirect` → opens the payment page via the injected `webAuthOpener`, then returns `.pending`
///   (the controller continues polling / confirms the terminal state on return).
/// - `qrCode` / `showContent` / `unknown` → returns `.failed(UNSUPPORTED_CAPABILITY)`,
///   and does **not** call the opener (no silent hang).
///
/// Core-pure: depends only on the `WebAuthOpening` protocol and touches no UI framework types.
struct ActionHandler: ActionHandling {
    /// Injection seam for opening a web authentication session; real implementation in Task 11.
    private let webAuthOpener: any WebAuthOpening

    /// Creates an action handler.
    ///
    /// - Parameter webAuthOpener: The injection seam used by the `redirect` action to open the payment page.
    init(webAuthOpener: any WebAuthOpening) {
        self.webAuthOpener = webAuthOpener
    }

    /// Handles a `requiresAction` action (see `ActionHandling.handle`).
    ///
    /// - Parameters:
    ///   - action: The action carried by the backend in the `R` state.
    ///   - sessionId: The current session identifier (not directly used by the first-version `redirect` flow; reserved for diagnostics / return matching).
    /// - Returns: `redirect` → `.pending`; everything else → `.failed(UNSUPPORTED_CAPABILITY)`.
    func handle(_ action: PaymentAction, sessionId: String) async -> ActionResult {
        switch action {
        case let .redirect(url):
            await webAuthOpener.open(url)
            return .pending
        case .qrCode, .showContent, .unknown:
            return .failed(
                CheckoutError(
                    code: "UNSUPPORTED_CAPABILITY",
                    message: "This payment action type is not supported in this SDK version.",
                    category: .runtime,
                    traceId: nil
                )
            )
        }
    }
}
