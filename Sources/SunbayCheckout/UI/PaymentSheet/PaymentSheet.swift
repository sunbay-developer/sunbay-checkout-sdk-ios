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
            /// Pay with a selected saved card (COF; the user selects a card then taps Pay).
            case confirmSavedCard(paymentMethodId: String)
            /// The Apple Pay wallet token has been obtained; confirm the wallet payment.
            case confirmWallet(token: Data)
            /// The user canceled.
            case cancel
        }

        /// What one pass of the retry loop produced.
        enum AttemptResult: Sendable, Equatable {
            /// The session (re)load failed before any confirm was attempted. NOT a payment outcome.
            case startFailed(CheckoutOutcome)
            /// A confirm (or a cancel) produced this outcome.
            case outcome(CheckoutOutcome)
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

        /// The host-configured locale (BCP-47), or nil to follow the system. Threaded to the content VC
        /// so the Pay-button amount and error messages format in the configured locale, consistent with
        /// the UI copy routed through `localize`.
        private let localeCode: String?

        /// The resolved appearance for the content + container, and the merchant color-scheme
        /// preference (drives `overrideUserInterfaceStyle`). Built in `present()` from the host
        /// configuration's appearance (or `.default`).
        private let appearance: Appearance

        /// Custom home-page title forwarded from the host configuration (optional). Only the home
        /// page consumes it; the new-card subpage keeps its built-in title.
        private let paymentSheetTitle: String?

        /// The address-metadata service threaded in from `SunbayCheckout` (already cache-wrapped),
        /// used to build the content VC's full-mode address form. UI-agnostic (Core type).
        private let addressMetadataService: any AddressMetadataService

        // MARK: - Public observation

        /// Observes the coarse-grained in-sheet presentation state (spec §3.4).
        ///
        /// The container forwards every internal state transition (editing / processing / succeeded /
        /// failed) to this closure on the main actor; hosts use it for analytics and never drive the
        /// flow through it. Defaults to `nil`.
        ///
        /// While the sheet is locked confirming an unresolved (pending / unknown) payment it reports
        /// `.editing` even though the inputs and the Pay button are locked (no new public state is
        /// added for it); do not treat `.editing` as "the user can change anything".
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
                localeCode: checkout.configuration.locale,
                appearance: checkout.configuration.appearance ?? .default,
                paymentSheetTitle: checkout.configuration.paymentSheetTitle,
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
        ///   - paymentSheetTitle: Custom home-page title; defaults to nil (uses the localized default).
        ///   - addressMetadataService: The address-metadata service for the full-mode address form;
        ///     defaults to a fail-soft empty service so existing call sites compile unchanged.
        init(
            controller: CheckoutController,
            sessionId: String,
            customerAccessSecret: String? = nil,
            localize: @escaping (String) -> String = LocalizationResolver(explicitLocale: nil).localizedNoComment,
            localeCode: String? = nil,
            appearance: Appearance = .default,
            paymentSheetTitle: String? = nil,
            addressMetadataService: any AddressMetadataService = EmptyAddressMetadataService()
        ) {
            self.controller = controller
            self.sessionId = sessionId
            self.customerAccessSecret = customerAccessSecret
            self.localize = localize
            self.localeCode = localeCode
            self.appearance = appearance
            self.paymentSheetTitle = paymentSheetTitle
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
        /// cancels / pulls the sheet down (`.canceled`, unless the last outcome was an unsettled
        /// `.pending` / `.unknown`, in which case that outcome is returned so the host knows to call
        /// `retrievePayment()`). Returns the result of a **single** presentation; `pending/unknown`
        /// still pair with `retrievePayment()` or server-side reconciliation.
        ///
        /// ## Pending / unknown and start failures
        /// After `.pending` / `.unknown` the sheet locks (Pay hidden, only ✕) and shows a neutral
        /// "we're confirming this payment; you can close; we won't double-charge" notice. The SDK does
        /// NOT poll: the sheet simply stays open until the user closes it, and the host reconciles the
        /// final state via `retrievePayment()` / webhook. A session (re)load failure inside the loop is
        /// never shown as a payment outcome: with an earlier unsettled attempt the sheet keeps waiting
        /// for the user to close; otherwise the presentation ends with that start failure.
        ///
        /// - Parameter presenter: The host view controller used to present the payment page modally.
        /// - Returns: The `CheckoutOutcome` of this presentation (user cancel before any unsettled
        ///   attempt → `.canceled`; close after `.pending` / `.unknown` → that outcome).
        @MainActor
        public func present(from presenter: UIViewController) async -> CheckoutOutcome {
            let coordinator = PresentationCoordinator(
                presenter: presenter,
                appearance: appearance,
                localize: localize,
                localeCode: localeCode,
                paymentSheetTitle: paymentSheetTitle,
                addressService: addressMetadataService,
                onStateChange: { [weak self] state in self?.onStateChange?(state) }
            )

            // Drive attempts until the content finishes (success auto-close / cancel) or the sheet is
            // canceled. Each confirm is exactly one `runAttempt` (one confirm → one outcome);
            // non-terminal outcomes keep the sheet open for the next confirm (no blind resubmit).
            var lastOutcome: CheckoutOutcome = .canceled
            loop: while true {
                var attempt = await runAttempt { context in
                    await coordinator.awaitNextAction(session: context.session, savedCards: context.savedCards)
                }

                // A session (re)load failure is NOT a payment outcome (F2). While an earlier attempt is
                // still unsettled the sheet is locked: do not touch the content, do not retry the load in
                // a loop; just wait for the user to close the sheet. Otherwise it ends the presentation
                // (handled below).
                if case .startFailed = attempt, PaymentSheet.isUnresolved(lastOutcome), !coordinator.wasCanceled {
                    attempt = await execute(await coordinator.awaitEvent())
                }

                // The user closed (✕ / backdrop / pull-down) → done. If the last known outcome was an
                // unsettled `.pending` / `.unknown`, report THAT instead of `.canceled`: a payment may be
                // in flight, so the host must reconcile via `retrievePayment()` rather than assume nothing
                // happened. A genuine cancel (nothing submitted, or a definite `.failed`) stays `.canceled`.
                if coordinator.wasCanceled {
                    lastOutcome = PaymentSheet.outcomeOnClose(lastKnown: lastOutcome)
                    break loop
                }

                switch attempt {
                case let .startFailed(failure):
                    // Nothing unresolved (see above): surface the start failure and stop. Never fed to the
                    // content, and never retried in-line (no hot loop while offline).
                    lastOutcome = failure
                    break loop
                case let .outcome(outcome):
                    lastOutcome = outcome
                    // Feed the outcome into the content; `.succeeded` auto-closes (→ finish), others stay
                    // open. `.pending` / `.unknown` lock the sheet (no polling); the user closes it and
                    // the host reconciles via `retrievePayment()`.
                    if await coordinator.applyOutcome(outcome) { break loop }
                }
                // Not finished: loop back and await the next confirm / cancel.
            }

            coordinator.dismiss()
            return lastOutcome
        }

        /// Whether `outcome` is an unsettled `.pending` / `.unknown` (a payment may be in flight).
        static func isUnresolved(_ outcome: CheckoutOutcome) -> Bool {
            switch outcome {
            case .pending, .unknown: return true
            case .succeeded, .failed, .canceled: return false
            }
        }

        /// The outcome `present()` reports when the user closes the sheet.
        ///
        /// - Parameter lastKnown: The outcome of the most recent attempt in this presentation
        ///   (`.canceled` if none was made).
        /// - Returns: `lastKnown` when it is `.pending` / `.unknown` (an unsettled payment the host must
        ///   reconcile with `retrievePayment()`); otherwise `.canceled`.
        static func outcomeOnClose(lastKnown: CheckoutOutcome) -> CheckoutOutcome {
            switch lastKnown {
            case .pending, .unknown:
                return lastKnown
            case .succeeded, .failed, .canceled:
                return .canceled
            }
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
            switch await runAttempt(seam: seam) {
            case let .startFailed(outcome), let .outcome(outcome):
                return outcome
            }
        }

        /// One pass of the checkout: the same flow as `runCheckout`, but it keeps "the session (re)load
        /// failed before any confirm" distinct from a confirm outcome so `present()` never feeds a load
        /// failure to the content as if it were a payment result.
        func runAttempt(
            seam: @Sendable (CheckoutContext) async -> UserAction
        ) async -> AttemptResult {
            // 1. Load the session.
            let session: CheckoutSession
            do {
                session = try await controller.start(
                    sessionId: sessionId,
                    customerAccessSecret: customerAccessSecret
                )
            } catch let error as CheckoutError {
                return .startFailed(.failed(txnId: nil, error: error))
            } catch {
                return .startFailed(.unknown(sessionId: sessionId))
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
            return await execute(action)
        }

        /// Drives the `controller.confirm*` call (or cancel) for a user action.
        func execute(_ action: UserAction) async -> AttemptResult {
            switch action {
            case let .confirmNewCard(input, save):
                // When checked to save, attach consent (§7.3; COF save requires consent).
                let consent = save ? Consent(version: "1.0") : nil
                return .outcome(await controller.confirmNewCard(input, save: save, consent: consent))
            case let .confirmSavedCard(paymentMethodId):
                return .outcome(await controller.confirmSavedCard(paymentMethodId: paymentMethodId))
            case let .confirmWallet(token):
                return .outcome(await controller.confirmWallet(token: token))
            case .cancel:
                await controller.dismiss()
                return .outcome(.canceled)
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
    /// ## Pending / unknown (no client polling)
    /// When an attempt ends `.pending` / `.unknown`, the content locks (Pay hidden, only ✕) and shows a
    /// neutral "we're confirming; you can close; we won't double-charge" notice. The coordinator does
    /// NOT poll: the sheet stays open until the user closes it, and the host reconciles the final state
    /// via `retrievePayment()` / webhook.
    /// ## No lost user action
    /// A user action emitted while the loop is not suspended (e.g. a Pay tap in the unlock window after a
    /// `.failed`, during the session reload) is buffered (at most one) and delivered to the next
    /// `awaitEvent`. A close/cancel still wins over a buffered action.
    ///
    /// The container is the content's delegate; this coordinator only wires the container's
    /// `onUserAction` / `onFinish` / `onStateChange` callbacks. `@MainActor` (UIKit affinity).
    @MainActor
    private final class PresentationCoordinator {
        private weak var presenter: UIViewController?
        private let appearance: Appearance
        private let localize: (String) -> String
        private let localeCode: String?
        private let paymentSheetTitle: String?
        private let addressService: any AddressMetadataService
        private let onStateChange: (CheckoutPresentationState) -> Void

        /// At most ONE user action that arrived while no one was suspended on `awaitEvent` (e.g. a Pay tap
        /// in the unlock window after a `.failed`, while the loop is still reloading the session). It is
        /// delivered to the next `awaitEvent`, so no user action is ever lost and the content (already in
        /// `.processing`) cannot get stuck. A close/cancel still wins over it.
        private var bufferedUserAction: PaymentSheet.UserAction?

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
            localeCode: String?,
            paymentSheetTitle: String?,
            addressService: any AddressMetadataService,
            onStateChange: @escaping (CheckoutPresentationState) -> Void
        ) {
            self.presenter = presenter
            self.appearance = appearance
            self.localize = localize
            self.localeCode = localeCode
            self.paymentSheetTitle = paymentSheetTitle
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
            return await awaitEvent()
        }

        /// Suspends until the next event for the loop: a user action or a cancel. A cancel wins over a
        /// buffered action (the closed sheet resolves with the outcome known at close time).
        func awaitEvent() async -> PaymentSheet.UserAction {
            await withCheckedContinuation { continuation in
                if wasCanceled {
                    bufferedUserAction = nil
                    continuation.resume(returning: .cancel)
                    return
                }
                if let action = bufferedUserAction {
                    bufferedUserAction = nil
                    continuation.resume(returning: action)
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
                localeCode: localeCode,
                billingMode: appearance.billingAddressMode,
                shippingMode: appearance.shippingAddressMode,
                addressService: addressService,
                homeTitle: paymentSheetTitle
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
            PaymentSheet.resignFirstResponder(in: presenter)
            presenter.present(containerVC, animated: true)
        }

        /// Resumes the suspended seam with a user action (guards against a double resume).
        ///
        /// When nobody is suspended (the loop is between awaits, e.g. reloading the session after a
        /// `.failed`), the action is buffered (at most one; a later `.cancel` replaces it, otherwise the
        /// first wins) and delivered by the next `awaitEvent` instead of being silently dropped.
        private func resumeAction(_ action: PaymentSheet.UserAction) {
            guard let continuation = actionContinuation else {
                if case .cancel = action {
                    bufferedUserAction = action
                } else if bufferedUserAction == nil {
                    bufferedUserAction = action
                }
                return
            }
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
        /// - `.failed`: the content shows the error and stays editable; report `false` so `present()`
        ///   awaits the next confirm.
        /// - `.pending` / `.unknown`: the content locks into its reconciling state (no Pay, only ✕);
        ///   report `false` so `present()` keeps the sheet open until the user closes it.
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
            case .failed:
                content?.applyOutcome(outcome)
                return false
            case .pending, .unknown:
                // Lock the sheet and show the neutral "we're confirming; you can close; we won't
                // double-charge" notice. The SDK does not poll — the user closes and the host
                // reconciles via `retrievePayment()`.
                content?.applyOutcome(outcome)
                return false
            }
        }

        /// Dismisses the sheet (if still presented).
        func dismiss() {
            container?.dismiss(animated: true)
        }
    }

    extension PaymentSheet {
        /// Dismisses any keyboard owned by the presenting screen before the sheet is presented.
        ///
        /// The sheet's presentation controller only learns about the keyboard from change
        /// notifications, which never fire for a keyboard that is already up at present time (the
        /// sheet would then render under it). Resigning first responder up front, as most modal UIs
        /// do, makes that state impossible: the keyboard is hidden and the overlap starts at zero.
        static func resignFirstResponder(in presenter: UIViewController) {
            presenter.view.endEditing(true)
        }
    }
#endif
