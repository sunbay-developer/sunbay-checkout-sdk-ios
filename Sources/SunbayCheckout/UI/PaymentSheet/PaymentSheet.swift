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
    /// Card-on-file is effective only when **all** of these hold: the session's `supportStoreCard`
    /// is true, `CheckoutConfiguration.cardOnFile.isEnabled` is true, and the host passed in a
    /// `customerAccessSecret`. When effective, the page shows the saved-card list (select a
    /// card to pay, zero verification) and a new card can still be checked to save; `storeCard` is
    /// sent only when the user's checkbox is on and COF is effective. Otherwise the page
    /// degrades to new card + wallet only, with no extra code needed from the host. Listing cards itself never throws
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
    /// `customerAccessSecret` is held in memory only (`CredentialStore`, cleared on success / dismiss /
    /// session expiry, not on failure), and does not enter `CheckoutOutcome`, logs, or any public return value.
    ///
    /// iOS-only: the whole thing is `#if canImport(UIKit)`; it does not compile under the macOS host (Core stays independent of UIKit).
    public final class PaymentSheet {
        /// The actions the user can select during one checkout presentation (see `CheckoutUserAction`).
        typealias UserAction = CheckoutUserAction
        /// What one pass of the retry loop produced (see `CheckoutAttemptResult`).
        typealias AttemptResult = CheckoutAttemptResult
        /// The context passed to the seam (see `CheckoutSessionContext`).
        typealias CheckoutContext = CheckoutSessionContext
        /// What `loadContext()` produced (see `CheckoutContextResult`).
        typealias ContextResult = CheckoutContextResult

        // MARK: - Dependencies

        /// The payment orchestrator. The public init assembles the real implementation via
        /// `SunbayCheckout.makeController`; the internal init injects it directly (a real actor
        /// assembled from a mock backend for unit tests).
        private let controller: CheckoutController
        /// The presentation-independent checkout logic (session load, method filtering, COF, host
        /// addresses, confirm dispatch). Holds the session id, credentials and host addresses.
        private let driver: CheckoutSessionDriver
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

        /// The card-rules source threaded in from `SunbayCheckout`; building the card form refreshes the
        /// cached rules through it.
        private let cardRulesService: any CardRulesService

        /// The wallet capability for the in-sheet Apple Pay row (real PassKit by default).
        private let walletAuthorizer: any WalletAuthorizing
        /// The resolved Apple Pay merchant id (host configuration first); nil hides the Apple Pay row.
        private let walletMerchantId: String?
        /// Screen metrics snapshot shared with the checkout's default payment service; recorded in `present`.
        private let screenMetrics: ScreenMetricsStore?
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
        /// instance (the host-injected ones or the default real-backend services).
        ///
        /// - Parameters:
        ///   - checkout: The SDK public entry point (holding the host configuration and injected backend services).
        ///   - sessionId: The session identifier to check out.
        ///   - customerAccessSecret: COF credential (optional); delivered by the host backend over HTTPS, held in memory only, never logged.
        ///   - checkoutClientSecret: Client secret issued by the host backend together with the session (optional); kept in memory only, never logged.
        ///   - billingAddress: A billing address the host already knows (optional). It is sent as is and wins over what the user enters in the SDK form; host-provided addresses are never validated. A new-card submit is blocked only by an invalid postal code in the SDK's address form; no other address field blocks a payment.
        ///   - shippingAddress: A shipping address the host already knows (optional); same rules as `billingAddress`.
        public convenience init(
            checkout: SunbayCheckout,
            sessionId: String,
            customerAccessSecret: String? = nil,
            checkoutClientSecret: String? = nil,
            billingAddress: AddressInput? = nil,
            shippingAddress: AddressInput? = nil
        ) {
            let wiring = checkout.makeUIWiring()
            self.init(
                controller: wiring.controller,
                sessionId: sessionId,
                customerAccessSecret: customerAccessSecret,
                checkoutClientSecret: checkoutClientSecret,
                billingAddress: billingAddress,
                shippingAddress: shippingAddress,
                localize: wiring.localize,
                localeCode: wiring.localeCode,
                appearance: wiring.appearance,
                paymentSheetTitle: wiring.paymentSheetTitle,
                addressMetadataService: wiring.addressMetadataService,
                cardRulesService: wiring.cardRulesService,
                walletAuthorizer: wiring.walletAuthorizer,
                walletMerchantId: wiring.walletMerchantId,
                screenMetrics: wiring.screenMetrics,
                paymentMethodFilter: wiring.paymentMethodFilter
            )
        }

        // MARK: - Internal initialization (dependency-injection seam, for mocks in unit tests)

        /// The internal initializer injecting a prebuilt controller (unit tests inject a real `CheckoutController` assembled from a mock backend through it).
        ///
        /// - Parameters:
        ///   - controller: The payment orchestrator.
        ///   - sessionId: The session identifier.
        ///   - customerAccessSecret: COF credential (optional).
        ///   - checkoutClientSecret: Client secret issued by the host backend with the session (optional).
        ///   - billingAddress: Host-provided billing address (optional; wins over the form).
        ///   - shippingAddress: Host-provided shipping address (optional; wins over the form).
        ///   - localize: Localized-string provider for the content copy; defaults to a nil-locale
        ///     resolver (system-preferred languages, then the `en` development localization), so
        ///     existing internal-init call sites compile unchanged.
        ///   - appearance: The appearance for the content + container; defaults to `.default` so
        ///     existing internal-init call sites (tests driving `runCheckout` directly) compile
        ///     unchanged.
        ///   - paymentSheetTitle: Custom home-page title; defaults to nil (uses the localized default).
        ///   - addressMetadataService: The address-metadata service for the full-mode address form;
        ///     defaults to a fail-soft empty service so existing call sites compile unchanged.
        ///   - walletAuthorizer: The wallet capability for the in-sheet Apple Pay row; defaults to the
        ///     real PassKit `WalletAuthorizer`.
        ///   - walletMerchantId: The resolved Apple Pay merchant id; defaults to nil (row hidden).
        init(
            controller: CheckoutController,
            sessionId: String,
            customerAccessSecret: String? = nil,
            checkoutClientSecret: String? = nil,
            billingAddress: AddressInput? = nil,
            shippingAddress: AddressInput? = nil,
            localize: @escaping (String) -> String = LocalizationResolver(explicitLocale: nil).localizedNoComment,
            localeCode: String? = nil,
            appearance: Appearance = .default,
            paymentSheetTitle: String? = nil,
            addressMetadataService: any AddressMetadataService = EmptyAddressMetadataService(),
            cardRulesService: any CardRulesService = EmptyCardRulesService(),
            walletAuthorizer: any WalletAuthorizing = WalletAuthorizer(),
            walletMerchantId: String? = nil,
            screenMetrics: ScreenMetricsStore? = nil,
            paymentMethodFilter: PaymentMethodFilter = PaymentMethodFilter()
        ) {
            self.screenMetrics = screenMetrics
            self.walletAuthorizer = walletAuthorizer
            self.walletMerchantId = walletMerchantId
            self.controller = controller
            self.localize = localize
            self.localeCode = localeCode
            self.appearance = appearance
            self.paymentSheetTitle = paymentSheetTitle
            self.addressMetadataService = addressMetadataService
            self.cardRulesService = cardRulesService
            self.driver = CheckoutSessionDriver(
                controller: controller,
                sessionId: sessionId,
                customerAccessSecret: customerAccessSecret,
                checkoutClientSecret: checkoutClientSecret,
                billingAddress: billingAddress,
                shippingAddress: shippingAddress,
                options: .forUI(appearance: appearance, failsWhenNoMethodAvailable: true),
                walletAuthorizer: walletAuthorizer,
                walletMerchantId: walletMerchantId,
                paymentMethodFilter: paymentMethodFilter)
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
        /// The session loads once per presentation (`loadContext`). The retry loop lives here: a
        /// `.failed` / `.pending` / `.unknown` outcome is fed back to the content (inline notice, the
        /// sheet stays open); the next user confirm produces another `didRequest` and another
        /// `execute` on the same loaded session (no reload). The loop
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
        /// final state via `retrievePayment()` / webhook. A session load failure is never shown as a
        /// payment outcome: the sheet is not presented and `present()` returns that start failure.
        ///
        /// - Parameter presenter: The host view controller used to present the payment page modally.
        /// - Returns: The `CheckoutOutcome` of this presentation (user cancel before any unsettled
        ///   attempt → `.canceled`; close after `.pending` / `.unknown` → that outcome).
        @MainActor
        public func present(from presenter: UIViewController) async -> CheckoutOutcome {
            // Snapshot the screen on the main actor; the submit path reads it off the main thread.
            screenMetrics?.recordMainScreen(presenter.view.window?.screen ?? UIScreen.main)
            let coordinator = PresentationCoordinator(
                presenter: presenter,
                appearance: appearance,
                localize: localize,
                localeCode: localeCode,
                paymentSheetTitle: paymentSheetTitle,
                addressService: addressMetadataService,
                cardRulesService: cardRulesService,
                walletAuthorizer: walletAuthorizer,
                walletMerchantId: walletMerchantId,
                walletContacts: { [controller] billing, shipping in
                    await controller.walletContactRequest(billingFormShown: billing, shippingFormShown: shipping)
                },
                onWalletParamsInvalid: { [controller] missing in
                    Task { await controller.reportWalletParamsInvalid(missing: missing) }
                },
                onStateChange: { [weak self] state in self?.onStateChange?(state) },
                deleteSavedCard: { [controller] id in await controller.deleteSavedCard(id: id) }
            )

            // Drive attempts until the content finishes (success auto-close / cancel) or the sheet is
            // canceled. Each loop pass takes one user action from the coordinator and `execute`s it
            // (one confirm → one outcome); non-terminal outcomes keep the sheet open for the next
            // confirm (no blind resubmit). The session loads once per presentation (`loadContext`). A failed first load is not a payment outcome:
            // nothing was presented, so return it as is.
            let context: CheckoutContext
            switch await loadContext() {
            case let .startFailed(failure):
                coordinator.dismiss()
                return failure
            case let .ready(loaded):
                context = loaded
            }

            var lastOutcome: CheckoutOutcome = .canceled
            loop: while true {
                let attempt = await execute(await coordinator.awaitNextAction(context: context))

                // The user closed (✕ / backdrop / pull-down) → done. If the last known outcome was an
                // unsettled `.pending` / `.unknown`, report THAT instead of `.canceled`: a payment may be
                // in flight, so the host must reconcile via `retrievePayment()` rather than assume nothing
                // happened. A genuine cancel (nothing submitted, or a definite `.failed`) stays `.canceled`.
                if coordinator.wasCanceled {
                    lastOutcome = PaymentSheet.outcomeOnClose(lastKnown: lastOutcome)
                    break loop
                }

                switch attempt {
                case .startFailed:
                    // Unreachable: `execute` never produces a start failure (the session loads once above).
                    assertionFailure("execute() must not produce a start failure")
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
            CheckoutSessionDriver.isUnresolved(outcome)
        }

        /// The outcome `present()` reports when the user closes the sheet (see `CheckoutSessionDriver.outcomeOnClose`).
        static func outcomeOnClose(lastKnown: CheckoutOutcome) -> CheckoutOutcome {
            CheckoutSessionDriver.outcomeOnClose(lastKnown: lastKnown)
        }

        /// A UI-independent result lookup (crash/kill recovery, §2.2 / §4.3). Delegates to the controller.
        ///
        /// - Returns: The latest `PaymentSnapshot`.
        /// - Throws: Propagates a lookup failure.
        public func retrievePayment() async throws -> PaymentSnapshot {
            try await driver.retrievePayment()
        }

        // MARK: - Internal testable logic (controller-driven)

        /// The testable core logic that drives one checkout (touches no real UIKit presentation).
        ///
        /// Flow:
        /// 1. `controller.start(sessionId:customerAccessSecret:checkoutClientSecret:)` loads and validates the session;
        ///    on a load failure → failures other than `.canceled` are thrown by start, and here
        ///    they are mapped as a fallback to `.unknown`/`.failed` (see below).
        /// 2. **Automatic COF inclusion**: when the effective COF decision (`controller.isCardOnFileEnabled`) is on,
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

        /// One load-then-confirm pass, used by `runCheckout` and tests. It keeps "the session load failed
        /// before any confirm" distinct from a confirm outcome. `present()` does not call it: it loads the
        /// context once via `loadContext()` and drives each attempt with the presentation coordinator.
        func runAttempt(
            seam: @Sendable (CheckoutContext) async -> UserAction
        ) async -> AttemptResult {
            switch await loadContext() {
            case let .startFailed(outcome):
                return .startFailed(outcome)
            case let .ready(context):
                // 3. Wait for the user action, then 4. drive the confirmation path.
                return await execute(await seam(context))
            }
        }

        /// Steps 1–2 of the checkout: load the session, apply the host filter and provider availability,
        /// decide COF and list saved cards. `present()` calls it once per presentation.
        func loadContext() async -> ContextResult {
            await driver.loadContext()
        }

        /// Drives the `controller.confirm*` call (or cancel) for a user action.
        func execute(_ action: UserAction) async -> AttemptResult {
            await driver.execute(action)
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
        private let cardRulesService: any CardRulesService
        private let walletAuthorizer: any WalletAuthorizing
        private let walletMerchantId: String?
        private let walletContacts: @Sendable (Bool, Bool) async -> WalletContactRequest
        private let onWalletParamsInvalid: @Sendable ([String]) -> Void
        private let onStateChange: (CheckoutPresentationState) -> Void
        private let deleteSavedCard: @Sendable (String) async -> Result<Void, CheckoutError>

        /// Hands user actions from the content to the retry loop. It buffers at most one action that arrives
        /// while nobody is waiting (so none is lost, e.g. a Pay tap during the unlock window after a
        /// `.failed`); a close/cancel always wins (see `UserActionChannel`).
        private let channel = UserActionChannel()

        private var content: CheckoutContentViewController?
        private var container: PaymentSheetContainerViewController?

        /// The continuation awaiting a content-driven finish (success auto-close), when applicable.
        private var finishContinuation: CheckedContinuation<Void, Never>?

        /// Set once the user canceled / pulled the sheet down; `present()` reads it to end the loop.
        var wasCanceled: Bool { channel.wasCanceled }
        /// Whether the sheet has already been presented (so later attempts reuse it).
        private var isPresented = false

        init(
            presenter: UIViewController,
            appearance: Appearance,
            localize: @escaping (String) -> String,
            localeCode: String?,
            paymentSheetTitle: String?,
            addressService: any AddressMetadataService,
            cardRulesService: any CardRulesService,
            walletAuthorizer: any WalletAuthorizing,
            walletMerchantId: String?,
            walletContacts: @escaping @Sendable (Bool, Bool) async -> WalletContactRequest,
            onWalletParamsInvalid: @escaping @Sendable ([String]) -> Void,
            onStateChange: @escaping (CheckoutPresentationState) -> Void,
            deleteSavedCard: @escaping @Sendable (String) async -> Result<Void, CheckoutError>
        ) {
            self.deleteSavedCard = deleteSavedCard
            self.presenter = presenter
            self.appearance = appearance
            self.localize = localize
            self.localeCode = localeCode
            self.paymentSheetTitle = paymentSheetTitle
            self.addressService = addressService
            self.cardRulesService = cardRulesService
            self.walletAuthorizer = walletAuthorizer
            self.walletMerchantId = walletMerchantId
            self.walletContacts = walletContacts
            self.onWalletParamsInvalid = onWalletParamsInvalid
            self.onStateChange = onStateChange
        }

        /// Builds + presents the sheet on first use, then suspends until the next confirm / cancel.
        ///
        /// - Parameters:
        ///   - session: The loaded session (used to build the content VC on first call).
        ///   - context: The loaded session, listed saved cards (COF) and the COF decision.
        /// - Returns: The next user action (or `.cancel` on cancel / pull-down / no presenter).
        func awaitNextAction(context: PaymentSheet.CheckoutContext) async -> PaymentSheet.UserAction {
            if !isPresented {
                presentSheet(context: context)
            }
            return await awaitEvent()
        }

        /// Suspends until the next event for the loop: a user action or a cancel. A cancel wins over a
        /// buffered action (the closed sheet resolves with the outcome known at close time).
        func awaitEvent() async -> PaymentSheet.UserAction {
            await channel.next()
        }

        /// Builds the content VC + container and presents it modally.
        private func presentSheet(context: PaymentSheet.CheckoutContext) {
            let resolved = ResolvedAppearance.resolve(appearance)
            let contentVC = CheckoutContentViewController(
                session: context.session,
                savedCards: context.savedCards,
                appearance: resolved,
                localize: localize,
                localeCode: localeCode,
                billingMode: .from(enabled: appearance.billingAddressEnabled),
                shippingMode: .from(enabled: appearance.shippingAddressEnabled),
                addressService: addressService,
                homeTitle: paymentSheetTitle,
                walletAuthorizer: walletAuthorizer,
                walletMerchantId: walletMerchantId,
                walletContacts: walletContacts,
                onWalletParamsInvalid: onWalletParamsInvalid,
                cardOnFileEnabled: context.cardOnFileEnabled,
                saveCardByDefault: context.saveCardByDefault,
                cardRulesService: cardRulesService,
                billingEntryUsable: context.billingEntryUsable,
                shippingEntryUsable: context.shippingEntryUsable,
                billingStyle: appearance.billingAddressStyle,
                shippingStyle: appearance.shippingAddressStyle,
                visibleEntries: context.visibleEntries
            )
            let containerVC = PaymentSheetContainerViewController(
                content: contentVC,
                appearance: resolved,
                colorScheme: appearance.colorScheme
            )
            containerVC.onUserAction = { [weak self] action in
                self?.channel.post(action)
            }
            containerVC.onFinish = { [weak self] outcome in
                self?.handleContainerFinish(outcome)
            }
            containerVC.onStateChange = { [weak self] state in
                self?.onStateChange(state)
            }
            containerVC.onDeleteSavedCard = deleteSavedCard

            content = contentVC
            container = containerVC
            isPresented = true

            guard let presenter else {
                // No presenter (abnormal): treat as cancel so the loop ends instead of hanging.
                channel.cancel()
                return
            }
            PaymentSheet.resignFirstResponder(in: presenter)
            presenter.present(containerVC, animated: true)
        }

        /// Handles a container-reported finish (success auto-close or cancel / pull-down).
        ///
        /// A cancel finish arrives when the user pulled the sheet down (the content never emitted a
        /// confirm). A success finish arrives after the content's success animation; it resolves the
        /// pending `applyOutcome` await so `present()` can return.
        private func handleContainerFinish(_ outcome: CheckoutOutcome) {
            switch outcome {
            case .canceled:
                // Unblock a suspended seam (user pulled down before confirming).
                channel.cancel()
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
