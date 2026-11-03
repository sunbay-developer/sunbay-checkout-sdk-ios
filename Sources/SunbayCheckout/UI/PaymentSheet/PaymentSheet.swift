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
    /// - `present(from:)` is just a thin UIKit wrapper: it builds a
    ///   `CheckoutContentViewController` (render + state machine) hosted in a
    ///   `PaymentSheetContainerViewController` (bottom sheet), bridges the content's user actions
    ///   into that `seam`, then `await`s `runCheckout` to get the `CheckoutOutcome` from the same
    ///   logic, and finally dismisses the sheet.
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
        /// Localized-string provider handed to the content VC so its copy renders in the configured
        /// locale. Built from a `LocalizationResolver`; maps a `sunbay.*` key to its localized
        /// string. Core stays UI-agnostic — the resolver lives in Core, the closure is consumed only
        /// here in the UI layer.
        private let localize: (String) -> String

        /// The resolved appearance for the content + container, and the merchant color-scheme
        /// preference (drives `overrideUserInterfaceStyle`). Built in `present()` from the host
        /// configuration's appearance (or `.default`).
        private let appearance: Appearance

        /// The address-metadata service threaded in from `SunbayCheckout` (already cache-wrapped),
        /// used to build the content VC's full-mode address form. UI-agnostic (Core type).
        private let addressMetadataService: any AddressMetadataService

        // MARK: - Public observation

        /// Observes the coarse-grained in-sheet presentation state (spec §3.4).
        ///
        /// The container forwards every internal state transition (editing / processing / succeeded /
        /// failed) to this closure on the main actor; hosts use it for analytics and never drive the
        /// flow through it. Defaults to `nil`.
        public var onStateChange: ((CheckoutPresentationState) -> Void)?

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
                localize: LocalizationResolver(explicitLocale: checkout.configuration.locale).localizedNoComment,
                appearance: checkout.configuration.appearance ?? .default,
                addressMetadataService: checkout.addressMetadataService
            )
        }

        // MARK: - Internal initialization (dependency-injection seam, for mocks in unit tests)

        /// The internal initializer injecting a prebuilt controller (unit tests inject a real `CheckoutController` assembled from a mock backend through it).
        ///
        /// - Parameters:
        ///   - controller: The payment orchestrator.
        ///   - sessionId: The session identifier.
        ///   - customerAccessSecret: COF credential (optional).
        ///   - localize: Localized-string provider for the content copy; defaults to a nil-locale
        ///     resolver (system-preferred languages, then the `en` development localization), so
        ///     existing internal-init call sites compile unchanged.
        ///   - appearance: The appearance for the content + container; defaults to `.default` so
        ///     existing internal-init call sites (tests driving `runCheckout` directly) compile
        ///     unchanged.
        ///   - addressMetadataService: The address-metadata service for the full-mode address form;
        ///     defaults to a fail-soft empty service so existing call sites compile unchanged.
        init(
            controller: CheckoutController,
            sessionId: String,
            customerAccessSecret: String? = nil,
            localize: @escaping (String) -> String = LocalizationResolver(explicitLocale: nil).localizedNoComment,
            appearance: Appearance = .default,
            addressMetadataService: any AddressMetadataService = EmptyAddressMetadataService()
        ) {
            self.controller = controller
            self.sessionId = sessionId
            self.customerAccessSecret = customerAccessSecret
            self.localize = localize
            self.appearance = appearance
            self.addressMetadataService = addressMetadataService
        }

        // MARK: - Public API

        /// Pops the payment page and waits for the user to complete one operation (§2.2).
        ///
        /// Builds the resolved appearance, the host-agnostic `CheckoutContentViewController`, and the
        /// `PaymentSheetContainerViewController`, presents the container, and bridges the content's
        /// `didRequest` confirm intents into `runCheckout` — driving start → (COF) list → confirm →
        /// outcome per attempt — feeding each outcome back to the content via `applyOutcome(_:)`.
        ///
        /// ## Retry loop
        /// `runCheckout` stays single-shot (one seam → one confirm → one outcome, preserving the
        /// existing `PaymentSheetTests`). The retry loop lives here: a `.failed` / `.pending` /
        /// `.unknown` outcome is fed back to the content (inline notice, the sheet stays open); the
        /// next user confirm produces another `didRequest` and another `runCheckout` attempt. The loop
        /// ends when the content finishes (`didFinishWith` — e.g. a success auto-close) or the user
        /// cancels / pulls the sheet down (`.canceled`). Returns the result of a **single**
        /// presentation; `pending/unknown` still pair with `retrievePayment()` or server-side
        /// reconciliation.
        ///
        /// - Parameter presenter: The host view controller used to present the payment page modally.
        /// - Returns: The `CheckoutOutcome` of this presentation (user cancel → `.canceled`).
        @MainActor
        public func present(from presenter: UIViewController) async -> CheckoutOutcome {
            let coordinator = PresentationCoordinator(
                presenter: presenter,
                appearance: appearance,
                localize: localize,
                addressService: addressMetadataService,
                onStateChange: { [weak self] state in self?.onStateChange?(state) }
            )

            // Drive attempts until the content finishes (success auto-close / cancel) or the sheet is
            // canceled. Each confirm is exactly one `runCheckout` attempt (one confirm → one outcome);
            // non-terminal outcomes keep the sheet open for the next confirm (no blind resubmit).
            var lastOutcome: CheckoutOutcome = .canceled
            loop: while true {
                let outcome = await runCheckout { context in
                    await coordinator.awaitNextAction(session: context.session, savedCards: context.savedCards)
                }

                // The user canceled or pulled the sheet down before confirming → done.
                if await coordinator.wasCanceled {
                    lastOutcome = .canceled
                    break loop
                }

                lastOutcome = outcome
                // Feed the outcome into the content; `.succeeded` auto-closes (→ finish), others stay
                // open for retry. `applyOutcome` returns once the content has reacted.
                let finished = await coordinator.applyOutcome(outcome)
                if finished {
                    break loop
                }
                // Non-terminal: loop back and await the next confirm (or a cancel).
            }

            await coordinator.dismiss()
            return lastOutcome
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

    /// Main-actor bridge between the retry-loop `present()` logic and the presented container/content.
    ///
    /// `present()` owns the loop (one `runCheckout` per confirm); this coordinator owns the UIKit
    /// objects and the continuations that connect them:
    /// - `awaitNextAction` lazily builds + presents the container (on the first call, once the
    ///   session has loaded) and suspends until the content emits the next `didRequest` (→ the
    ///   returned `UserAction`) or the user cancels / pulls down (→ `.cancel`).
    /// - `applyOutcome` forwards the attempt's outcome to the content and resolves whether the
    ///   presentation finished: `.succeeded` auto-closes (await the content's `didFinishWith`), while
    ///   non-terminal outcomes keep the sheet open for another confirm.
    ///
    /// The container is the content's delegate; this coordinator only wires the container's
    /// `onUserAction` / `onFinish` / `onStateChange` callbacks. `@MainActor` (UIKit affinity).
    @MainActor
    private final class PresentationCoordinator {
        private weak var presenter: UIViewController?
        private let appearance: Appearance
        private let localize: (String) -> String
        private let addressService: any AddressMetadataService
        private let onStateChange: (CheckoutPresentationState) -> Void

        private var content: CheckoutContentViewController?
        private var container: PaymentSheetContainerViewController?

        /// The continuation awaiting the next user action (set while a seam call is suspended).
        private var actionContinuation: CheckedContinuation<PaymentSheet.UserAction, Never>?
        /// The continuation awaiting a content-driven finish (success auto-close), when applicable.
        private var finishContinuation: CheckedContinuation<Void, Never>?

        /// Set once the user canceled / pulled the sheet down; `present()` reads it to end the loop.
        private(set) var wasCanceled = false
        /// Whether the sheet has already been presented (so later attempts reuse it).
        private var isPresented = false

        init(
            presenter: UIViewController,
            appearance: Appearance,
            localize: @escaping (String) -> String,
            addressService: any AddressMetadataService,
            onStateChange: @escaping (CheckoutPresentationState) -> Void
        ) {
            self.presenter = presenter
            self.appearance = appearance
            self.localize = localize
            self.addressService = addressService
            self.onStateChange = onStateChange
        }

        /// Builds + presents the sheet on first use, then suspends until the next confirm / cancel.
        ///
        /// - Parameters:
        ///   - session: The loaded session (used to build the content VC on first call).
        ///   - savedCards: The listed saved cards (COF).
        /// - Returns: The next user action (or `.cancel` on cancel / pull-down / no presenter).
        func awaitNextAction(session: CheckoutSession, savedCards: [SavedCard]) async -> PaymentSheet.UserAction {
            if !isPresented {
                presentSheet(session: session, savedCards: savedCards)
            }
            return await withCheckedContinuation { continuation in
                if wasCanceled {
                    continuation.resume(returning: .cancel)
                    return
                }
                actionContinuation = continuation
            }
        }

        /// Builds the content VC + container and presents it modally.
        private func presentSheet(session: CheckoutSession, savedCards: [SavedCard]) {
            let resolved = ResolvedAppearance.resolve(appearance)
            let contentVC = CheckoutContentViewController(
                session: session,
                savedCards: savedCards,
                appearance: resolved,
                localize: localize,
                billingMode: appearance.billingAddressMode,
                shippingMode: appearance.shippingAddressMode,
                addressService: addressService
            )
            let containerVC = PaymentSheetContainerViewController(
                content: contentVC,
                appearance: resolved,
                colorScheme: appearance.colorScheme
            )
            containerVC.onUserAction = { [weak self] action in
                self?.resumeAction(action)
            }
            containerVC.onFinish = { [weak self] outcome in
                self?.handleContainerFinish(outcome)
            }
            containerVC.onStateChange = { [weak self] state in
                self?.onStateChange(state)
            }

            content = contentVC
            container = containerVC
            isPresented = true

            guard let presenter else {
                // No presenter (abnormal): treat as cancel so the loop ends instead of hanging.
                wasCanceled = true
                resumeAction(.cancel)
                return
            }
            presenter.present(containerVC, animated: true)
        }

        /// Resumes the suspended seam with a user action (guards against a double resume).
        private func resumeAction(_ action: PaymentSheet.UserAction) {
            guard let continuation = actionContinuation else { return }
            actionContinuation = nil
            continuation.resume(returning: action)
        }

        /// Handles a container-reported finish (success auto-close or cancel / pull-down).
        ///
        /// A cancel finish arrives when the user pulled the sheet down (the content never emitted a
        /// confirm). A success finish arrives after the content's success animation; it resolves the
        /// pending `applyOutcome` await so `present()` can return.
        private func handleContainerFinish(_ outcome: CheckoutOutcome) {
            switch outcome {
            case .canceled:
                wasCanceled = true
                // Unblock a suspended seam (user pulled down before confirming).
                resumeAction(.cancel)
            default:
                break
            }
            // Unblock a pending success await.
            if let finish = finishContinuation {
                finishContinuation = nil
                finish.resume()
            }
        }

        /// Feeds the attempt outcome to the content and reports whether the presentation finished.
        ///
        /// - `.succeeded`: the content animates success then emits `didFinishWith`; await that and
        ///   report `true` (loop ends).
        /// - `.canceled`: finished (`true`).
        /// - non-terminal (`.failed` / `.pending` / `.unknown`): the content shows a notice and stays
        ///   editable; report `false` so `present()` awaits the next confirm.
        ///
        /// - Returns: `true` when the presentation has finished; `false` to keep the sheet open.
        func applyOutcome(_ outcome: CheckoutOutcome) async -> Bool {
            switch outcome {
            case .canceled:
                return true
            case .succeeded:
                content?.applyOutcome(outcome)
                // Await the content's success auto-close (`didFinishWith` → container `onFinish`).
                await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                    if wasCanceled {
                        continuation.resume()
                        return
                    }
                    finishContinuation = continuation
                }
                return true
            case .failed, .pending, .unknown:
                content?.applyOutcome(outcome)
                return false
            }
        }

        /// Dismisses the sheet (if still presented).
        func dismiss() async {
            container?.dismiss(animated: true)
        }
    }
#endif
