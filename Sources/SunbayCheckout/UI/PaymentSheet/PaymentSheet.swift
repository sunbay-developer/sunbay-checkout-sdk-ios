#if canImport(UIKit)
    import UIKit

    /// L1 — the black-box payment page `PaymentSheet` (product-spec §2.2).
    ///
    /// ## Positioning
    /// The host constructs this object from a `SunbayCheckout` entry point + `sessionId`
    /// (optional `customerAccessSecret`), and calls `present(from:)` to pop a modal payment
    /// page; the page automatically renders the available payment methods (new-card form,
    /// Apple Pay option, and — when COF is available — the saved-card list), and resolves back
    /// as a `CheckoutOutcome` after the user completes one operation. All business orchestration
    /// lives in `CheckoutController` (an actor); this shell only renders, forwards user actions,
    /// and returns the result, holding no business rules.
    ///
    /// ## Automatic COF inclusion (§2.2)
    /// When **both** "the host passed in a `customerAccessSecret`" and "the session
    /// `cofEnabled == true`" hold, the page automatically shows the saved-card list (select a
    /// card to pay, zero verification), and a new card can still be checked to save. The
    /// authority to decide availability is on the backend (it delivers `cofEnabled`), and the
    /// client follows automatically: no secret or the backend has COF off → degrades to new card
    /// + wallet only, with no extra code needed from the host. Listing cards itself never throws
    /// (`CheckoutController.listSavedCards` degrades internally).
    ///
    /// ## Testable logic vs. the `present()` wrapper (split rationale)
    /// A headless xctest cannot reliably drive real UIKit presentation, so the
    /// **controller-driven logic** of "start → (per COF decision) list → wait for user action →
    /// confirm → outcome" is narrowed into the internal, testable method `runCheckout(seam:)`:
    /// - `seam` is an `async` closure that receives a `CheckoutContext` (containing the loaded
    ///   session and the listed saved cards) and returns the user-selected `UserAction` (confirm
    ///   new card / select saved card / wallet / cancel).
    /// - `present(from:)` is just a thin UIKit wrapper: it constructs and presents a
    ///   `PaymentSheetViewController`, bridges the VC's user actions into that `seam`, then
    ///   `await`s `runCheckout` to get the `CheckoutOutcome` from the same logic, and finally
    ///   dismisses the VC.
    ///
    /// Unit tests inject a mock controller through the internal initializer, call
    /// `runCheckout(seam:)` directly, and trigger the target action via `seam`, thereby verifying
    /// start/list/confirm/outcome without touching real presentation; the full UI is verified by
    /// the example app (Task 13).
    ///
    /// ## Security (§5)
    /// Card plaintext is only encrypted via `CardInput → CardEncryptor` (inside
    /// `CheckoutController.confirmNewCard`), and is never logged/persisted/returned;
    /// `customerAccessSecret` is held in memory only (`CredentialStore`, cleared at the terminal
    /// state), and does not enter `CheckoutOutcome`, logs, or any public return value.
    ///
    /// iOS-only: the whole thing is `#if canImport(UIKit)`; it does not compile under the macOS host (Core stays independent of UIKit).
    public final class PaymentSheet {
        /// The actions the user can select during one checkout presentation (produced by the VC / test seam).
        ///
        /// internal: used only to pass user intent between the shell and the testable logic/tests, not exposed externally.
        enum UserAction: Sendable {
            /// Confirm a new card (optionally checked to save + consent).
            case confirmNewCard(CardInput, save: Bool)
            /// Select a saved card (COF one-tap pay).
            case confirmSavedCard(paymentMethodId: String)
            /// The Apple Pay wallet token has been obtained; confirm the wallet payment.
            case confirmWallet(token: Data)
            /// The user canceled.
            case cancel
        }

        /// The context passed to the seam: the loaded session and the (per COF decision) listed saved cards.
        ///
        /// internal: the VC / tests render options from it and return a `UserAction`.
        struct CheckoutContext: Sendable {
            /// The loaded session, validated as not expired.
            let session: CheckoutSession
            /// The listed saved cards; empty when COF is unavailable (no secret / off).
            let savedCards: [SavedCard]
        }

        // MARK: - Dependencies

        /// The payment orchestrator. The public init assembles the real implementation via
        /// `SunbayCheckout.makeController`; the internal init injects it directly (a real actor
        /// assembled from a mock backend for unit tests).
        private let controller: CheckoutController
        private let sessionId: String
        /// COF credential (optional); held in memory only and passed to `CheckoutController.start`, never logged/returned (§5).
        private let customerAccessSecret: String?
        /// Localized-string provider handed to `PaymentSheetViewController` so its titles render
        /// in the configured locale. Built from a `LocalizationResolver`; maps a `sunbay.sheet.*`
        /// key to its title. Core stays UI-agnostic — the resolver lives in Core, the closure is
        /// consumed only here in the UI layer.
        private let localize: (String) -> String

        // MARK: - Public initialization (assembles the real dependencies)

        /// Constructs the payment page from a `SunbayCheckout` entry point and a session identifier (the public entry point used by the host, §2.2).
        ///
        /// Assembles a real `CheckoutController` through the `SunbayCheckout.makeController` seam
        /// (injecting a real `ActionHandler` + `WebAuthOpener` and an in-memory
        /// `CredentialStore`); the controller uses the backend services held by the `checkout`
        /// instance (the host-injected ones or the fail-closed defaults).
        ///
        /// - Parameters:
        ///   - checkout: The SDK public entry point (holding the host configuration and injected backend services).
        ///   - sessionId: The session identifier to check out.
        ///   - customerAccessSecret: COF credential (optional); delivered by the host backend over HTTPS, held in memory only, never logged.
        public convenience init(
            checkout: SunbayCheckout,
            sessionId: String,
            customerAccessSecret: String? = nil
        ) {
            let controller = checkout.makeController(
                credentials: CredentialStore(),
                actionHandler: ActionHandler(webAuthOpener: WebAuthOpener())
            )
            self.init(
                controller: controller,
                sessionId: sessionId,
                customerAccessSecret: customerAccessSecret,
                localize: LocalizationResolver(explicitLocale: checkout.configuration.locale).localizedNoComment
            )
        }

        // MARK: - Internal initialization (dependency-injection seam, for mocks in unit tests)

        /// The internal initializer injecting a prebuilt controller (unit tests inject a real `CheckoutController` assembled from a mock backend through it).
        ///
        /// - Parameters:
        ///   - controller: The payment orchestrator.
        ///   - sessionId: The session identifier.
        ///   - customerAccessSecret: COF credential (optional).
        ///   - localize: Localized-string provider for the VC titles; defaults to a nil-locale
        ///     resolver (system-preferred languages, then the `en` development localization), so
        ///     existing internal-init call sites compile unchanged.
        init(
            controller: CheckoutController,
            sessionId: String,
            customerAccessSecret: String? = nil,
            localize: @escaping (String) -> String = LocalizationResolver(explicitLocale: nil).localizedNoComment
        ) {
            self.controller = controller
            self.sessionId = sessionId
            self.customerAccessSecret = customerAccessSecret
            self.localize = localize
        }

        // MARK: - Public API

        /// Pops the payment page and waits for the user to complete one operation (§2.2).
        ///
        /// A thin UIKit wrapper: constructs `PaymentSheetViewController`, and `runCheckout(seam:)`
        /// drives start → (after the COF decision) list → present the VC → wait for user action →
        /// confirm → outcome; dismisses the VC once complete. Returns the result of a **single**
        /// presentation; `pending/unknown` need to be paired with `retrievePayment()` or
        /// server-side reconciliation.
        ///
        /// - Parameter presenter: The host view controller used to present the payment page modally.
        /// - Returns: The `CheckoutOutcome` of this presentation (user cancel → `.canceled`).
        @MainActor
        public func present(from presenter: UIViewController) async -> CheckoutOutcome {
            // The VC holder: used to present it during the seam phase of runCheckout and to bridge its user actions.
            var viewController: PaymentSheetViewController?

            let outcome = await runCheckout { [weak presenter] context in
                // Construct and present the VC on the main thread, and await its user action as the result of this seam.
                await withCheckedContinuation { (continuation: CheckedContinuation<UserAction, Never>) in
                    Task { @MainActor in
                        let vc = PaymentSheetViewController(
                            session: context.session,
                            savedCards: context.savedCards,
                            localize: self.localize
                        )
                        viewController = vc
                        vc.onAction = { action in
                            continuation.resume(returning: action)
                        }
                        vc.modalPresentationStyle = .formSheet
                        if let presenter {
                            presenter.present(vc, animated: true)
                        } else {
                            // No presenter (abnormal) → treat as cancel, to avoid hanging.
                            continuation.resume(returning: .cancel)
                        }
                    }
                }
            }

            // Dismiss the VC (if presented).
            await MainActor.run {
                viewController?.dismiss(animated: true)
            }
            return outcome
        }

        /// A UI-independent result lookup (crash/kill recovery, §2.2 / §4.3). Delegates to the controller.
        ///
        /// - Returns: The latest `PaymentSnapshot`.
        /// - Throws: Propagates a lookup failure.
        public func retrievePayment() async throws -> PaymentSnapshot {
            try await controller.retrievePayment(sessionId: sessionId)
        }

        // MARK: - Internal testable logic (controller-driven)

        /// The testable core logic that drives one checkout (touches no real UIKit presentation).
        ///
        /// Flow:
        /// 1. `controller.start(sessionId:customerAccessSecret:)` loads and validates the session;
        ///    on a load failure → failures other than `.canceled` are thrown by start, and here
        ///    they are mapped as a fallback to `.unknown`/`.failed` (see below).
        /// 2. **Automatic COF inclusion**: when `customerAccessSecret != nil && session.cofEnabled`,
        ///    call `controller.listSavedCards()` (degrades internally, never throws); otherwise do
        ///    not drive card listing and savedCards is empty.
        /// 3. Call `seam` with a `CheckoutContext` to get the user `UserAction`.
        /// 4. Drive the corresponding `controller.confirm*` per the action; `.cancel` → `.canceled`.
        ///
        /// - Parameter seam: An async closure that receives the context and returns the user action (`present` implements it with the VC; tests provide it directly).
        /// - Returns: The `CheckoutOutcome` of this checkout.
        func runCheckout(
            seam: @Sendable (CheckoutContext) async -> UserAction
        ) async -> CheckoutOutcome {
            // 1. Load the session.
            let session: CheckoutSession
            do {
                session = try await controller.start(
                    sessionId: sessionId,
                    customerAccessSecret: customerAccessSecret
                )
            } catch let error as CheckoutError {
                return .failed(txnId: nil, error: error)
            } catch {
                return .unknown(sessionId: sessionId)
            }

            // 2. Automatic COF inclusion decision (§2.2): has secret and the backend has COF on → list cards; otherwise do not.
            let savedCards: [SavedCard]
            if customerAccessSecret != nil && session.cofEnabled {
                savedCards = await controller.listSavedCards()
            } else {
                savedCards = []
            }

            // 3. Wait for the user action.
            let action = await seam(CheckoutContext(session: session, savedCards: savedCards))

            // 4. Drive the confirmation path.
            switch action {
            case let .confirmNewCard(input, save):
                // When checked to save, attach consent (§7.3; COF save requires consent).
                let consent = save ? Consent(version: "1.0") : nil
                return await controller.confirmNewCard(input, save: save, consent: consent)
            case let .confirmSavedCard(paymentMethodId):
                return await controller.confirmSavedCard(paymentMethodId: paymentMethodId)
            case let .confirmWallet(token):
                return await controller.confirmWallet(token: token)
            case .cancel:
                await controller.dismiss()
                return .canceled
            }
        }
    }
#endif
