#if canImport(UIKit)
    import AuthenticationServices
    import Foundation
    import UIKit

    /// The real implementation of `WebAuthOpening` (the Task 8 protocol seam): uses the system
    /// `ASWebAuthenticationSession` to open a third-party APM redirect page (e.g. the Alipay
    /// web page), with a returnUrl callback (product-spec §4.5).
    ///
    /// ## Responsibilities and boundary
    /// - Responsible only for "opening a redirect URL in the system's secure browser, and
    ///   ending the session when it is redirected back to the agreed scheme". The terminal
    ///   state continues to be confirmed by Core via polling / callback (authorization/open
    ///   success ≠ transaction success, §3.2).
    /// - **Touches no card data**: what the redirect opens is a third-party APM payment web
    ///   page, which is standard practice (§4.5 boundary clarification).
    /// - iOS-only: the whole thing is gated by `#if canImport(UIKit)`, with
    ///   `import AuthenticationServices` placed inside it; it does not compile under the macOS
    ///   host (Core stays independent of UIKit/AuthenticationServices).
    ///
    /// ## Callback scheme
    /// `ASWebAuthenticationSession` identifies the return redirect by a "callback URL scheme":
    /// the returnUrl delivered by the backend has the form `<scheme>://...`, and the system
    /// closes the browser and calls back when the user is redirected back to that scheme. This
    /// type constructs the session with an injected `callbackURLScheme` (the custom scheme the
    /// host App registers in `Info.plist`); when empty, it degrades to "open only, confirmed by
    /// external polling" (iOS 17+ can use `.callback(.customScheme:)`; here the most
    /// cross-version-robust `callbackURLScheme:` form is used).
    ///
    /// ## async semantics
    /// Implements `func open(_ url: URL) async`: starts the session and `await`s until the user
    /// completes or cancels (redirect back / closing the browser), then returns — **fully
    /// consistent** with the Task 8 protocol signature (no return value, no throws). The session
    /// result (redirect URL / cancel / error) is not treated as a transaction conclusion and is
    /// left to Core polling; so here it only awaits the session's end and does not surface it.
    struct WebAuthOpener: WebAuthOpening {
        /// The callback custom scheme registered by the host App (e.g. `"sunbaycheckout"`); when empty, no return redirect is bound.
        let callbackURLScheme: String?

        /// Creates a web authentication opener.
        ///
        /// - Parameter callbackURLScheme: The callback custom scheme; defaults to nil (open only, terminal state confirmed externally).
        init(callbackURLScheme: String? = nil) {
            self.callbackURLScheme = callbackURLScheme
        }

        /// Opens a third-party APM redirect page and waits for the user to complete / cancel (see the type description).
        ///
        /// - Parameter url: The redirect address delivered by the backend in the `redirect` action.
        func open(_ url: URL) async {
            let scheme = callbackURLScheme
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                // ASWebAuthenticationSession must be created / started on the main thread (UI-related).
                Task { @MainActor in
                    let anchorProvider = PresentationAnchorProvider()
                    let session = ASWebAuthenticationSession(
                        url: url,
                        callbackURLScheme: scheme
                    ) { _, _ in
                        // The redirect URL / cancel / error are none of them treated as a transaction conclusion; only mark "session ended".
                        // The terminal state is confirmed by Core polling / callback (§3.2 / §4.5). Nothing is logged (§5).
                        continuation.resume()
                    }
                    session.presentationContextProvider = anchorProvider
                    session.prefersEphemeralWebBrowserSession = false
                    // Hold anchorProvider until the session ends, avoiding premature release.
                    anchorProvider.retainSession = session
                    if !session.start() {
                        continuation.resume()
                    }
                }
            }
        }
    }

    /// Provides the presentation anchor (the current key window) for `ASWebAuthenticationSession`.
    ///
    /// The system requires an implementation of `ASWebAuthenticationPresentationContextProviding`
    /// to return a window. It takes the key window of the current foreground `UIWindowScene`;
    /// when none can be obtained, it falls back to an empty `ASPresentationAnchor`.
    @MainActor
    private final class PresentationAnchorProvider: NSObject,
        ASWebAuthenticationPresentationContextProviding
    {
        /// Holds the session until the callback fires, preventing it from being released prematurely.
        var retainSession: ASWebAuthenticationSession?

        func presentationAnchor(
            for session: ASWebAuthenticationSession
        ) -> ASPresentationAnchor {
            let scene = UIApplication.shared.connectedScenes
                .compactMap { $0 as? UIWindowScene }
                .first { $0.activationState == .foregroundActive }
            if let window = scene?.windows.first(where: { $0.isKeyWindow }) ?? scene?.windows.first {
                return window
            }
            return ASPresentationAnchor()
        }
    }
#endif
