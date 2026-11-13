#if canImport(UIKit)
    import UIKit

    /// The host-agnostic checkout content (spec §3, Task 8): it composes the Task 6/7 components into a
    /// scrolling column, owns the visible `CheckoutStateMachine`, and talks to the outside world only
    /// through `CheckoutContentDelegate`. It never references the container or `CheckoutController`.
    ///
    /// ## Composition (fixed header · scrolling middle · fixed bottom bar)
    /// A fixed `header` is pinned to the top; a scroll view holds the middle (express row on the home
    /// page only, then either the saved-card list or the new-card subpage with its card form, "Save
    /// this card" toggle, and billing/shipping address); a fixed bottom bar holds the inline notice,
    /// the Pay button, and the powered-by footer (hugging the bottom). Only the middle scrolls.
    ///
    /// ## Navigation (option A — self-managed)
    /// The home page is always the root (express · saved-card list, if any · standalone "New card"
    /// entry row, ordered by `expressPosition`). Tapping "New card" switches to the independent
    /// new-card subpage and shows the header back button; back returns home. The express (wallet)
    /// row is a home-page affordance: hidden on the subpage. Selecting a saved card does NOT submit —
    /// it only enables the Pay button. On the home page the Pay button is hidden while no saved card
    /// is selected; on the new-card subpage it is always visible, dimmed (but still tappable, so a
    /// tap surfaces the field error) until the form is complete. Navigation and the entry row are
    /// locked while a confirm is in flight.
    ///
    /// ## State wiring (spec §3.2)
    /// A confirm (pay with new card / tap a saved card / Apple Pay authorized) moves the machine to
    /// `.processing`, disables inputs, drives the `ConfirmButton` spinner, emits
    /// `delegate.didChangeProcessing(true)` + `didChangeState(.processing)`, then emits
    /// `delegate.content(didRequest:)`. The container drives the controller and feeds the result back
    /// via `applyOutcome(_:)`, which runs the machine and reacts: `.autoClose` animates success then
    /// `didFinishWith`; `.showError` shows the inline error and re-enables; `.showInfoNotice`
    /// (`pending` / `unknown`) enters the locked `.reconciling` state: Pay hidden, inputs locked, a
    /// "confirming your payment, please don't try again" notice, only ✕ available (never back to an
    /// interactive state, so a second tap cannot resubmit; Core also refuses — defense in depth). The processing phase is held for at least
    /// `ConfirmButton.minimumFlightTime` before the terminal UI is applied, to avoid a flicker.
    ///
    /// iOS-only: gated by `#if canImport(UIKit)`; does not compile under the macOS host (`swift test`).
    final class CheckoutContentViewController: UIViewController {
        // MARK: - Delegate

        /// The content boundary. The container (Task 9) implements it; held weakly to avoid a cycle.
        weak var delegate: CheckoutContentDelegate?

        // MARK: - Injected dependencies

        private let session: CheckoutSession
        /// The saved-card list state (order, selection, default, expiry, deletes in flight).
        private var selection: SavedCardSelection
        private var savedCards: [SavedCard] { selection.cards }
        /// Whether the full saved-card list is in manage mode (delete buttons shown).
        private var isManagingSavedCards = false
        /// Cards with a delete request in flight (a second request for the same card is ignored).
        private var deletingCardIds: Set<String> { selection.deletingIds }
        /// Shared brand-logo loader (in-memory cache) for saved-card rows.
        private let logoLoader = CardBrandLogoLoader()
        #if DEBUG
            /// The card id staged by the test seam for `confirmDeleteForTest()`.
            private var pendingDeleteCardId: String?
        #endif
        /// Whether the (filtered) session offers a card; no card → no new-card row and no saved cards.
        private let cardAvailable: Bool
        /// The card brands (with session logos) shown in the card-number field.
        private let cardBrandItems: [CardBrandItem]
        /// Whether the host filter left an `APPLE_PAY` entry in place.
        private let applePayVisible: Bool
        /// Whether the home page offers anything besides the express (wallet) row. Drives the
        /// "Or pay using" divider; extend it when the card area gains other payment methods.
        private var hasNonExpressMethods: Bool { cardAvailable }
        private let appearance: ResolvedAppearance
        private let localize: (String) -> String
        /// The host-configured locale (BCP-47), or nil to follow the system. Drives amount formatting
        /// (`payTitle`) and error-message localization (`localizedFailure`) so both honor
        /// `CheckoutConfiguration.locale`, exactly like the UI copy does via `localize`.
        private let localeCode: String?
        private let billingMode: AddressCollectionMode
        private let shippingMode: AddressCollectionMode
        private let addressService: any AddressMetadataService

        // MARK: - State

        private var stateMachine = CheckoutStateMachine()

        /// When a confirm started, so `applyOutcome` can hold the processing phase for at least
        /// `ConfirmButton.minimumFlightTime` before applying a terminal result (avoids a flicker).
        private var processingStartedAt: Date?

        /// A pre-staged Apple Pay wallet token (test hook). When set, an Apple Pay tap confirms it
        /// directly instead of running the PassKit authorization.
        private var pendingWalletToken: Data?

        /// The wallet capability (device availability + PassKit authorization). nil means no real
        /// authorization is wired (tests that stage a token instead).
        private let walletAuthorizer: (any WalletAuthorizing)?
        /// The resolved Apple Pay merchant id (host configuration first); nil = not configured.
        private let walletMerchantId: String?
        /// Resolves the contacts to request for a tap from the controller, given which SDK address forms are shown.
        /// nil (no controller wired) requests none.
        private let walletContacts: (@Sendable (Bool, Bool) async -> WalletContactRequest)?
        /// Reports the names of unusable Apple Pay parameters (once per session via the diagnostics dedup).
        private let onWalletParamsInvalid: (@Sendable ([String]) -> Void)?
        /// Set while the PassKit sheet is up, so a second tap cannot start a parallel authorization.
        private var isAuthorizingWallet = false
        /// Resumed by `applyOutcome` with the outcome of an in-sheet wallet confirm, so the Apple Pay
        /// sheet can show the backend-derived status before it closes.
        private var walletOutcomeContinuation: CheckedContinuation<CheckoutOutcome, Never>?

        // MARK: - Components

        private lazy var header = SheetHeaderView(appearance: appearance, localize: localize)
        /// The card-brand rules in effect for this screen (cached remote > bundled), fixed at creation.
        private let cardRuleSet = CardRulesProvider.activeRuleSet()
        private let cardBinService: any CardBinService
        private let cardRulesService: any CardRulesService
        /// The new-card entry column (card form, save row, address forms); built with the layout.
        private var newCardEntry: NewCardEntryView?
        private lazy var confirmButton = ConfirmButton(appearance: appearance)
        private lazy var notice = InlineNoticeView(appearance: appearance)
        private lazy var footer = CheckoutFooterView(appearance: appearance, localize: localize)

        private var savedCardList: SavedCardListView?
        /// The home-page collapsed saved-card summary (one `SavedCardRow` + optional "View more").
        private var savedCardSummary: UIView?
        /// The home-page "View more" affordance (present whenever there is at least one saved card).
        private var viewMoreAffordance: UIView?
        private var expressView: ExpressCheckoutView?
        private var newCardEntryRow: UIView?

        /// The effective card-on-file decision (session allows it, host option on, secret held).
        private let cardOnFileEnabled: Bool
        /// Initial state of the save-card checkbox; the user can still change it before paying.
        private let saveCardByDefault: Bool


        // MARK: - Layout containers

        /// Fixed top chrome (merchant title + back/close). Pinned above the scroll area.
        private let headerContainer = UIView()
        /// The scrollable middle: express (home only) + saved-card list OR new-card subpage.
        private let scrollView = UIScrollView()
        private let rootStack = UIStackView()
        /// The HOME page column: express (if available) + saved-card list (if any) + "New card"
        /// entry row. Always present; shown when not on the new-card subpage.
        private let homeStack = UIStackView()
        /// The subpage that holds new-card entry (card form + save toggle + address). Hidden while the
        /// home page is shown.
        private let newCardStack = UIStackView()
        /// The full saved-card list page ("View more"): the complete `SavedCardListView`. Hidden until
        /// the user taps "View more"; picking a row selects it and returns home.
        private let allSavedCardsStack = UIStackView()
        /// Fixed bottom chrome: inline notice (above the CTA) + Pay button + powered-by footer.
        private let bottomBar = UIStackView()

        /// Whether the new-card subpage (vs the home page) is currently visible.
        private var isShowingNewCard = false

        /// Whether the full saved-card list page ("View more") is currently visible. On this page the
        /// bottom Pay button is hidden: the page is a pure picker (tap a row to select and return
        /// home), so there is no in-page confirm — Pay reappears on the home page.
        private var isShowingAllSavedCards = false

        /// The saved card the user has selected on the home page (nil = none selected). Selecting a
        /// row does NOT submit; the user must tap the Pay button (which this enables).
        private var selectedSavedCardId: String? {
            get { selection.selectedId }
            set { selection.setSelectedId(newValue) }
        }

        private var lastReportedHeight: CGFloat = 0

        /// Custom home-page title (optional). Only the home page reads it; the new-card subpage keeps
        /// its built-in title.
        private let homeTitle: String?

        // MARK: - Init

        /// Creates the content VC.
        ///
        /// - Parameters:
        ///   - session: The loaded checkout session (amount / merchant / methods).
        ///   - savedCards: The saved cards to list (empty when COF is unavailable).
        ///   - appearance: The resolved appearance tokens.
        ///   - localize: The localization closure for all copy.
        ///   - localeCode: The host-configured locale (BCP-47), or nil to follow the system. Drives the
        ///     Pay-button amount formatting and error-message localization so they honor the configured
        ///     locale (defaults to nil = system, keeping existing call sites unchanged).
        ///   - billingMode: The configured billing-address collection mode; `.automatic` follows the
        ///     session's `collectBillingAddress` flag (resolved here).
        ///   - shippingMode: The configured shipping-address collection mode; `.automatic` follows the
        ///     session's `collectShippingAddress` flag (resolved here).
        ///   - addressService: The address-metadata service (for the full address form).
        ///   - homeTitle: Optional custom home-page title (nil → the localized default pay title).
        ///   - walletAuthorizer: The wallet capability used for the Apple Pay row (device gating +
        ///     PassKit authorization). nil keeps the row token-staging only (tests).
        ///   - walletMerchantId: The resolved Apple Pay merchant id; the row is hidden when a
        ///     `walletAuthorizer` is given but no merchant id is configured.
        ///   - cardOnFileEnabled: The effective COF decision; shows the save-card row iff true.
        ///   - saveCardByDefault: Whether the save-card checkbox starts ticked.
        ///   - cardBinService: BIN recognition (internal; the empty default keeps local prefix matching).
        ///   - cardRulesService: Remote rules refresh (internal; the empty default keeps the cached /
        ///     bundled rules).
        ///   - billingEntryUsable: Whether the host supplied a complete billing address the session collects;
        ///     `.automatic` then shows no billing form.
        ///   - shippingEntryUsable: Same for the shipping address.
        ///   - billingStyle: Form style when `billingMode` is `.automatic` and resolves to shown.
        ///   - shippingStyle: Same for the shipping address.
        init(
            session: CheckoutSession,
            savedCards: [SavedCard],
            appearance: ResolvedAppearance,
            localize: @escaping (String) -> String,
            localeCode: String? = nil,
            billingMode: AddressCollectionMode,
            shippingMode: AddressCollectionMode,
            addressService: any AddressMetadataService,
            homeTitle: String? = nil,
            walletAuthorizer: (any WalletAuthorizing)? = nil,
            walletMerchantId: String? = nil,
            walletContacts: (@Sendable (Bool, Bool) async -> WalletContactRequest)? = nil,
            onWalletParamsInvalid: (@Sendable ([String]) -> Void)? = nil,
            cardOnFileEnabled: Bool = false,
            saveCardByDefault: Bool = false,
            cardBinService: any CardBinService = EmptyCardBinService(),
            cardRulesService: any CardRulesService = EmptyCardRulesService(),
            billingEntryUsable: Bool = false,
            shippingEntryUsable: Bool = false,
            billingStyle: Appearance.AddressFormStyle = .simple,
            shippingStyle: Appearance.AddressFormStyle = .simple,
            visibleEntries: [MethodEntry]? = nil
        ) {
            let entries = visibleEntries ?? session.methodEntries
            self.cardAvailable = entries.contains { PaymentMethodModel.logicalKey($0) == "CARD" }
            self.cardBrandItems = CardBrandItem.items(from: entries)
            self.applePayVisible = entries.contains { PaymentMethodModel.logicalKey($0) == "APPLE_PAY" }
            self.cardOnFileEnabled = cardOnFileEnabled
            self.saveCardByDefault = saveCardByDefault
            self.cardBinService = cardBinService
            self.cardRulesService = cardRulesService
            self.walletAuthorizer = walletAuthorizer
            self.walletMerchantId = walletMerchantId
            self.walletContacts = walletContacts
            self.onWalletParamsInvalid = onWalletParamsInvalid
            self.session = session
            // Usable cards first; expired ones stay visible (dimmed) at the end and are never selected.
            self.selection = SavedCardSelection(cards: cardAvailable ? savedCards : [])
            self.appearance = appearance
            self.localize = localize
            self.localeCode = localeCode
            self.billingMode = .resolveAddressMode(
                billingMode, collect: session.collectBillingAddress, hasUsableEntry: billingEntryUsable,
                style: billingStyle)
            self.shippingMode = .resolveAddressMode(
                shippingMode, collect: session.collectShippingAddress, hasUsableEntry: shippingEntryUsable,
                style: shippingStyle)
            self.addressService = addressService
            self.homeTitle = homeTitle
            super.init(nibName: nil, bundle: nil)
        }

        @available(*, unavailable)
        required init?(coder: NSCoder) {
            fatalError("init(coder:) is not supported")
        }

        // MARK: - Lifecycle

        override func viewDidLoad() {
            super.viewDidLoad()
            view.backgroundColor = appearance.background
            buildLayout()
            configureHeader()
            configureConfirmButton()
            configureInitialNavigation()
            refreshConfirmButtonState()
            observeFieldFocus()
            // Refresh the rules in the background; they apply the next time the card form is shown.
            newCardEntry?.startBackgroundRefresh()
        }

        // MARK: - Keyboard focus

        /// Keeps the focused field visible: the container shrinks the sheet above the keyboard, so the
        /// scroll area gets shorter and the field may sit outside it.
        private func observeFieldFocus() {
            let center = NotificationCenter.default
            center.addObserver(
                self, selector: #selector(fieldDidBeginEditing(_:)),
                name: UITextField.textDidBeginEditingNotification, object: nil)
            center.addObserver(
                self, selector: #selector(fieldDidBeginEditing(_:)),
                name: UITextView.textDidBeginEditingNotification, object: nil)
        }

        @objc private func fieldDidBeginEditing(_ note: Notification) {
            guard let field = note.object as? UIView, field.isDescendant(of: scrollView) else { return }
            DispatchQueue.main.async { [weak self] in self?.scrollFocusedFieldIntoView() }
        }

        /// Scrolls the current first responder inside the scroll area into view (with a 16 pt margin).
        func scrollFocusedFieldIntoView() {
            guard let responder = Self.firstResponder(in: scrollView) else { return }
            let rect = scrollView.convert(responder.bounds, from: responder)
            scrollView.scrollRectToVisible(rect.insetBy(dx: 0, dy: -16), animated: true)
        }

        private static func firstResponder(in root: UIView) -> UIView? {
            if root.isFirstResponder { return root }
            for subview in root.subviews {
                if let found = firstResponder(in: subview) { return found }
            }
            return nil
        }

        override func viewDidLayoutSubviews() {
            super.viewDidLayoutSubviews()
            reportContentHeightIfChanged()
        }

        // MARK: - Public API

        /// The current internal view state (test / introspection readout).
        var currentViewState: CheckoutViewState { stateMachine.state }

        #if DEBUG
            // MARK: Layout readouts (internal, tests only)

            /// Test readout: whether the save-card row exists on the new-card page.
            var isSaveCardRowVisibleForTest: Bool { newCardEntry?.isSaveCardRowVisible ?? false }

            /// Test readout: the billing address form is part of the new-card page.
            var isBillingFormVisibleForTest: Bool { newCardEntry?.billingAddressView.map { !$0.isHidden } ?? false }

            /// Test readout: the shipping form is shown (section present).
            var isShippingFormVisibleForTest: Bool { newCardEntry?.shippingAddressView.map { !$0.isHidden } ?? false }

            /// The billing / shipping address form views (nil when the section is off).
            var billingAddressViewForTest: UIView? { newCardEntry?.billingAddressView }
            var shippingAddressViewForTest: UIView? { newCardEntry?.shippingAddressView }

            /// Test readout: the save-card checkbox state (false when the row is absent).
            var isSaveCardOnForTest: Bool { newCardEntry?.isSaveCardOn ?? false }

            /// Test seam: set the save-card checkbox as if the user toggled it.
            func setSaveCardForTest(_ on: Bool) { newCardEntry?.setSaveCard(on) }

            /// Test readout: the fixed header container view.
            var headerContainerForTest: UIView { headerContainer }
            /// Test readout: the scrollable middle area.
            var scrollViewForTest: UIScrollView { scrollView }
            /// Test readout: the fixed bottom bar.
            var bottomBarForTest: UIView { bottomBar }
            /// Test readout: the home-page "New card" entry row.
            var newCardEntryRowForTest: UIView? { newCardEntryRow }
            /// Test readout: the express checkout view, when present.
            var expressViewForTest: UIView? { expressView }
            /// Test readout: the home-visible saved-card view (the collapsed summary), when present.
            var savedCardListViewForTest: UIView? { savedCardSummary }

            /// Test readout: whether the card form is currently interactive (re-enabled after a failure).
            var isCardFormInteractiveForTest: Bool { newCardEntry?.isCardFormInteractive ?? false }

            /// Test readout: whether the primary CTA is interactive (enabled) right now. After a `.failed`
            /// outcome with a complete form this must be `true` so the user can retry (spec §3.1/§3.2) —
            /// the button is `isEnabled` only in its `.enabled` status, so this reflects the fix that moves
            /// the CTA off `.processing` on the `.failed`→editing transition.
            var isConfirmButtonEnabledForTest: Bool { confirmButton.isEnabled }
        #endif

        /// Applies a confirm outcome: runs the state machine and drives the UI per spec §3.2.
        ///
        /// The processing phase is held for at least `ConfirmButton.minimumFlightTime` from the confirm
        /// tap before the terminal UI is applied, so a fast backend does not cause a spinner flicker.
        ///
        /// - Parameters:
        ///   - outcome: The terminal / intermediate outcome from the confirm dispatch.
        ///   - completion: Called on the main thread right after the outcome's UI has been applied
        ///     (possibly deferred by the minimum processing time). Lets the caller sequence work (e.g.
        ///     starting an auto-reconcile) strictly after the sheet has locked.
        func applyOutcome(_ outcome: CheckoutOutcome, completion: (() -> Void)? = nil) {
            // Answer a waiting Apple Pay sheet right away (not after the minimum flight time), so the
            // system sheet shows success / failure as soon as the backend has answered.
            resumeWalletOutcome(outcome)

            let elapsed = processingStartedAt.map { Date().timeIntervalSince($0) } ?? 0
            let remaining = max(0, ConfirmButton.minimumFlightTime - elapsed)

            guard remaining > 0 else {
                performApply(outcome)
                completion?()
                return
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + remaining) { [weak self] in
                self?.performApply(outcome)
                completion?()
            }
        }

        /// Runs the machine and reacts to its `StepResult`, emitting the state change.
        private func performApply(_ outcome: CheckoutOutcome) {
            let result = stateMachine.apply(outcome, localizedFailure: localizedFailure(_:))
            emitStateChange()

            switch result {
            case let .autoClose(finalOutcome):
                // This path never goes through `returnToEditing`; keep ✕ locked during the animation.
                header.setCloseEnabled(false)
                confirmButton.isHidden = false
                confirmButton.update(status: .succeeded, animated: true) { [weak self] in
                    guard let self else { return }
                    self.delegate?.content(self, didFinishWith: finalOutcome)
                }

            case let .showError(message):
                notice.show(message: message, severity: .error)
                returnToEditing()
                reportContentHeightIfChanged()

            case .showInfoNotice:
                notice.show(message: localize("sunbay.notice.reconciling"), severity: .info)
                enterReconciling()
                reportContentHeightIfChanged()

            case .stay:
                // e.g. canceled: let the caller handle dismissal; no visible change here.
                break
            }
        }

        #if DEBUG
            // MARK: - Test seams

            /// Fills the card form with a valid test card (bypasses keystrokes). By default it first lets any
            /// address form finish loading, since a Pay tap is ignored while address metadata loads; pass
            /// `awaitingAddressLoad: false` to test that window.
            func fillCardForTest(awaitingAddressLoad: Bool = true) {
                if awaitingAddressLoad {
                    (billingAddressViewForTest as? DynamicAddressFormView)?.waitForLoadForTest()
                    (shippingAddressViewForTest as? DynamicAddressFormView)?.waitForLoadForTest()
                }
                newCardEntry?.fillCardForTest(awaitingAddressLoad: false)
                refreshConfirmButtonState()
            }

            /// Simulates a confirm tap on the primary CTA (routes by page / selection).
            func simulateTapPay() {
                handlePayTapped()
            }

            /// Test seam: select a saved card as if the user tapped its row (does NOT submit).
            func selectSavedCardForTest(_ paymentMethodId: String) {
                selectedSavedCardId = paymentMethodId
                refreshConfirmButtonState()
            }

            /// Test seam: selects a saved card as if it were chosen, without any page navigation.
            /// This is a pure, side-effect-free selection seam — it mirrors what the real selection
            /// wiring ultimately does (set `selectedSavedCardId`, rebuild the summary, refresh the CTA)
            /// but deliberately does NOT drive the "View more" drill-in. The full-list open/pick path
            /// has its own seams (`tapViewMoreForTest` + `tapFullListRowForTest`), so this seam stays
            /// out of navigation timing for unrelated flow tests.
            func tapSavedCardRowForTest(_ paymentMethodId: String) {
                selectedSavedCardId = paymentMethodId
                rebuildSavedCardSummary()
                refreshConfirmButtonState()
            }

            /// Test seam: taps the "New card" entry row's action.
            func tapNewCardEntryForTest() {
                handleNewCardEntryTap()
            }

            /// Test seam: taps the header back button's action.
            func tapBackForTest() {
                header.onBack?()
            }

            /// Test seam: simulates a tap on the empty background of the scrolling form.
            func simulateBackgroundTapForTest() {
                handleBackgroundTap()
            }

            /// Test seam: delivers a touch to the Pay button (only if it is an enabled, tappable control).
            func sendTouchOnPayButtonForTest() {
                confirmButton.simulateTouchUpInsideForTest()
            }

            /// Test seam: simulates the Apple Pay row tap.
            func tapExpressForTest() {
                handleApplePayTapped()
            }

            /// Test readout: the currently selected/highlighted saved-card payment method id.
            var highlightedSavedCardIdForTest: String? { selectedSavedCardId }

            /// Test readout: whether the home "View more" affordance is present and visible (2+ cards).
            var isViewMoreVisibleForTest: Bool {
                guard let v = viewMoreAffordance else { return false }
                return !v.isHidden && !homeStack.isHidden
            }

            /// Test readout: whether the home summary's saved-card row is announced as a tappable button
            /// (it must NOT be: the summary body is static; only "View more" navigates).
            var isSummaryRowButtonForTest: Bool {
                guard let summary = savedCardSummary else { return false }
                func find(_ v: UIView) -> SavedCardRow? {
                    if let row = v as? SavedCardRow { return row }
                    for sub in v.subviews { if let r = find(sub) { return r } }
                    return nil
                }
                return find(summary)?.accessibilityTraits.contains(.button) ?? false
            }

            /// Test readout: whether the Pay button is dimmed (appears disabled) yet still tappable.
            var isConfirmButtonAppearsDisabledForTest: Bool { confirmButton.appearsDisabled }

            /// Test readout: the Pay button's accessibility traits.
            var confirmButtonTraitsForTest: UIAccessibilityTraits { confirmButton.accessibilityTraitsForTest }

            /// Test readout: whether the card form currently shows a field error.
            var isCardFieldErrorShownForTest: Bool { newCardEntry?.hasCardFieldError ?? false }

            /// Test readout: the Pay button's current title (to assert locale-formatted amount).
            var payButtonTitleForTest: String { confirmButton.titleForTest }

            /// Test readout: the localized message for an error, using the configured locale (to assert
            /// error localization honors `CheckoutConfiguration.locale`).
            func localizedFailureForTest(_ error: CheckoutError) -> String { localizedFailure(error) }

            /// Test readout: whether the inline notice (error / info) is currently shown.
            var isNoticeVisibleForTest: Bool { !notice.isHidden }

            /// Test readout: the inline notice's current message text (nil when hidden).
            var noticeMessageForTest: String? { notice.isHidden ? nil : notice.messageForTest }

            /// Test readout: whether the home page (express, list, "New card" entry) accepts touches.
            var isHomeInteractiveForTest: Bool { homeStack.isUserInteractionEnabled }

            /// Test readout: whether the header back button is interactive.
            var isBackInteractiveForTest: Bool { header.isBackEnabledForTest }

            /// Test readout: whether the header ✕ is interactive.
            var isCloseInteractiveForTest: Bool { header.isCloseEnabledForTest }

            /// Test readout: whether the header ✕ is visible (shown on home, hidden on sub-pages).
            var isCloseVisibleForTest: Bool { header.isCloseVisibleForTest }

            /// Test readout: whether the header ✕ exposes the `.notEnabled` accessibility trait.
            var closeHasNotEnabledTraitForTest: Bool { header.closeHasNotEnabledTraitForTest }

            /// Test seam: invokes the header's close action directly (as a programmatic / accessibility
            /// activation would), bypassing the button's enabled state.
            func invokeHeaderCloseForTest() { header.onClose?() }

            /// Test readout: the visible home-page order, as `"express"`, `"savedCards"`, `"newCardEntry"`.
            var homeOrderForTest: [String] {
                homeStack.arrangedSubviews.compactMap { view in
                    if view === expressView { return "express" }
                    if view === savedCardSummary { return "savedCards" }
                    if view === newCardEntryRow { return "newCardEntry" }
                    return nil
                }
            }

            /// Test seam: open the independent new-card subpage (as if the user tapped the "New card"
            /// entry on the home page).
            func openNewCardForTest() {
                showNewCardSubpage(animated: false)
            }

            /// Test readout: whether the primary CTA is currently visible (shown only when submittable).
            var isConfirmButtonVisibleForTest: Bool { !confirmButton.isHidden }

            /// Test readout: whether the HOME page (express + saved cards + "New card" entry) is visible.
            var isHomeVisibleForTest: Bool { !homeStack.isHidden }

            /// Test readout: whether the independent new-card subpage (card form) is visible.
            var isNewCardSubpageVisibleForTest: Bool { !newCardStack.isHidden }

            /// Test readout: whether the full saved-card list page ("View more") is visible.
            var isAllSavedCardsVisibleForTest: Bool { !allSavedCardsStack.isHidden }

            /// Test seam: taps the home "View more" affordance (opens the full saved-card list page).
            /// Test readout: the saved-card ids in display order.
            var savedCardOrderForTest: [String] { savedCards.map(\.id) }

            /// Test readouts / seams for saved-card management.
            var isManagingForTest: Bool { isManagingSavedCards }
            var headerActionTitleForTest: String? { header.actionTitleForTest }
            func tapManageForTest() { header.onAction?() }
            func tapDeleteForTest(_ id: String) { pendingDeleteCardId = id }
            func confirmDeleteForTest() {
                if let id = pendingDeleteCardId { performDelete(id) }
            }

            func tapViewMoreForTest() {
                showAllSavedCards()
            }

            /// Test seam: taps a row on the full saved-card list page (select + auto-return home).
            func tapFullListRowForTest(_ paymentMethodId: String) {
                savedCardList?.tapRowForTest(paymentMethodId)
            }

            /// Test readout: whether the express (wallet) row exists AND is currently visible. It lives in
            /// the home page, so it is visible only while the home page is shown.
            var isExpressVisibleForTest: Bool {
                guard let express = expressView else { return false }
                return !express.isHidden && !homeStack.isHidden
            }
        #endif

        // MARK: - Confirm handling

        /// Pay with the manually entered new card.
        private func handleConfirmNewCard() {
            guard let action = newCardEntry?.makeConfirmAction(), beginProcessing() else { return }
            delegate?.content(self, didRequest: action)
        }

        /// Pay with a selected saved card (COF; the user selected the card, then tapped Pay).
        private func handleConfirmSavedCard(paymentMethodId: String) {
            // Never submit an expired (or unknown) saved card.
            guard let card = savedCards.first(where: { $0.id == paymentMethodId }),
                  expiredText(for: card) == nil, !deletingCardIds.contains(paymentMethodId) else { return }
            guard beginProcessing() else { return }
            delegate?.content(self, didRequest: .confirmSavedCard(paymentMethodId: paymentMethodId))
        }

        /// Confirm a wallet payment once a token has been obtained.
        private func handleConfirmWallet(token: Data) {
            guard beginProcessing() else { return }
            delegate?.content(
                self,
                didRequest: .confirmWallet(
                    WalletAuthorization(token: token, billing: nil, shipping: nil, email: nil,
                                        merchantIdentifier: walletMerchantId),
                    billingFormShown: newCardEntry?.billingFormShown ?? false,
                    shippingFormShown: newCardEntry?.shippingFormShown ?? false))
        }

        /// Moves to the processing phase: machine, CTA spinner, disabled inputs, delegate notices.
        ///
        /// - Returns: `false` (and changes nothing) when a confirm must not start: one is already in
        ///   flight, or an earlier attempt is unsettled (`.reconciling`). Callers must NOT emit a
        ///   `didRequest` in that case.
        @discardableResult
        private func beginProcessing() -> Bool {
            // Re-entrancy guard: a confirm already in flight must not be fired again, independent of the
            // UI enabled-state (a double-tap or a programmatic re-trigger).
            // Also refuse while reconciling: an unsettled earlier attempt must not be re-submitted.
            guard !stateMachine.state.isLockedAgainstNewConfirm else { return false }
            notice.hide()
            newCardEntry?.clearCardError()
            processingStartedAt = Date()
            stateMachine.beginProcessing()
            // Visible on every page: a wallet confirm on the home page (nothing selected) must still
            // show the spinner. `refreshConfirmButtonState` re-applies page visibility afterwards.
            confirmButton.isHidden = false
            confirmButton.update(status: .processing, animated: false)
            setInputsEnabled(false)
            delegate?.content(self, didChangeProcessing: true)
            emitStateChange()
            // The notice was hidden and the Pay button may have just appeared (wallet-only home).
            reportContentHeightIfChanged()
            return true
        }

        /// Returns to the editable state after a non-success outcome, re-enabling inputs.
        ///
        /// On the `.showError` path the machine's state is `.failed(reason:)` (not `.editing`); the CTA
        /// must still be moved off `.processing` so the user can retry (spec §3.1/§3.2). This is why
        /// `refreshConfirmButtonState()` treats `.failed` as an editable state and resets the CTA to
        /// `.enabled`/`.disabled` by submittability rather than leaving it spinning.
        private func returnToEditing() {
            processingStartedAt = nil
            setInputsEnabled(true)
            refreshConfirmButtonState()
            delegate?.content(self, didChangeProcessing: false)
        }

        /// Enters the locked `.reconciling` presentation after `pending` / `unknown`.
        ///
        /// Unlike `returnToEditing`, nothing becomes interactive again: Pay is hidden and every input
        /// stays disabled (a second tap could duplicate the charge if the first attempt actually
        /// succeeded). Only the header ✕ is re-enabled so the user can leave; the sheet then returns the
        /// `.pending` / `.unknown` outcome and the host reconciles via `retrievePayment()`.
        private func enterReconciling() {
            processingStartedAt = nil
            setInputsEnabled(false)
            // ✕ is the only affordance that can leave the locked reconciling state (back is disabled),
            // and a confirm can be initiated from the new-card subpage where ✕ is normally hidden.
            // Re-show and enable it here so the user is never trapped, regardless of the current page.
            header.setCloseVisible(true)
            header.setCloseEnabled(true)
            confirmButton.update(status: .disabled, animated: false)
            confirmButton.isHidden = true
            delegate?.content(self, didChangeProcessing: false)
        }

        /// Emits the current public presentation state to the delegate.
        private func emitStateChange() {
            delegate?.content(self, didChangeState: stateMachine.presentationState)
        }

        // MARK: - Failure localization

        /// Maps a `CheckoutError` to a user-facing message, preferring the localized display message.
        private func localizedFailure(_ error: CheckoutError) -> String {
            // Prefer the key-mapped localized message; the Core extension falls back to `message` for
            // unmapped codes. Route through a resolver so the mapping is consistent with the rest of
            // the SDK; when the environment yields no mapping the developer-facing message is used.
            let resolver = LocalizationResolver(explicitLocale: localeCode)
            return error.localizedDisplayMessage(using: resolver)
        }

        // MARK: - Enable / disable

        /// Enables or disables the editable inputs during / after processing.
        private func setInputsEnabled(_ enabled: Bool) {
            newCardEntry?.setInteractionEnabled(enabled)
            // The whole home page (express, saved list, "New card" entry) and the back button: no
            // navigation while a confirm is in flight. The header ✕ is locked the same way.
            homeStack.isUserInteractionEnabled = enabled
            header.setBackEnabled(enabled)
            header.setCloseEnabled(enabled)
            header.setActionEnabled(enabled)
            savedCardList?.isUserInteractionEnabled = enabled
            expressView?.isUserInteractionEnabled = enabled
        }

        /// Updates the CTA for the current page.
        ///
        /// Home page: the Pay button is visible+enabled only when a saved card is selected, and
        /// hidden otherwise (e.g. a wallet-only home shows no bottom Pay button). New-card subpage:
        /// always visible; dimmed (`appearsDisabled`, still tappable) until the form is complete.
        /// Full saved-card list page ("View more"): Pay is hidden — that page is a pure picker.
        ///
        /// Safe to call while the machine is `.editing` **or** `.failed` — both are editable states
        /// where the user may (re)submit. It must not clobber the CTA while a confirm is in flight
        /// (`.processing`), during the success animation (`.succeeded`), or while reconciling an unsettled
        /// outcome (`.reconciling`: Pay must stay hidden), so those are guarded out.
        private func refreshConfirmButtonState() {
            switch stateMachine.state {
            case .processing, .succeeded, .reconciling:
                return
            case .editing, .failed:
                break
            }

            let wasHidden = confirmButton.isHidden
            defer {
                // The Pay button changes the fixed bottom bar's height: re-report the content height
                // (guarded by `lastReportedHeight`, so this cannot loop).
                if confirmButton.isHidden != wasHidden { reportContentHeightIfChanged() }
            }

            if isShowingAllSavedCards {
                // Full list page is a pure picker: no in-page confirm, Pay returns on the home page.
                confirmButton.appearsDisabled = false
                confirmButton.isHidden = true
                confirmButton.update(status: .disabled, animated: false)
            } else if isShowingNewCard {
                // Subpage: Pay is always visible. An incomplete form looks disabled but stays
                // tappable, so a tap runs `handleConfirmNewCard` and surfaces the field error.
                confirmButton.isHidden = false
                confirmButton.update(status: .enabled, animated: false)
                confirmButton.appearsDisabled = !(newCardEntry?.isComplete ?? false)
            } else {
                // Home: Pay is hidden unless a saved card is selected.
                let submittable = selectedSavedCardId != nil
                confirmButton.appearsDisabled = false
                confirmButton.isHidden = !submittable
                confirmButton.update(status: submittable ? .enabled : .disabled, animated: false)
            }
        }

        // MARK: - Layout construction

        private func buildLayout() {
            headerContainer.translatesAutoresizingMaskIntoConstraints = false
            scrollView.translatesAutoresizingMaskIntoConstraints = false
            // Dragging the form dismisses the keyboard (Stripe parity).
            scrollView.keyboardDismissMode = .onDrag
            // Tapping any non-interactive area of the sheet (header, form background, bottom bar)
            // dismisses the keyboard. It lives on the root view so it covers the whole sheet in one
            // place. `cancelsTouchesInView = false` keeps every control working; the delegate skips
            // taps on fields/controls.
            let backgroundTap = UITapGestureRecognizer(target: self, action: #selector(handleBackgroundTap))
            backgroundTap.cancelsTouchesInView = false
            backgroundTap.delegate = self
            view.addGestureRecognizer(backgroundTap)
            bottomBar.translatesAutoresizingMaskIntoConstraints = false

            view.addSubview(headerContainer)
            view.addSubview(scrollView)
            view.addSubview(bottomBar)

            // Fixed header.
            header.translatesAutoresizingMaskIntoConstraints = false
            headerContainer.addSubview(header)

            // Scrollable middle.
            rootStack.axis = .vertical
            rootStack.spacing = 16
            rootStack.translatesAutoresizingMaskIntoConstraints = false
            scrollView.addSubview(rootStack)

            newCardStack.axis = .vertical
            newCardStack.spacing = 16
            newCardStack.translatesAutoresizingMaskIntoConstraints = false

            // Fixed bottom bar: notice → Pay → footer (powered-by hugs the bottom).
            bottomBar.axis = .vertical
            bottomBar.spacing = 12
            bottomBar.addArrangedSubview(notice)
            bottomBar.addArrangedSubview(confirmButton)
            bottomBar.addArrangedSubview(footer)

            NSLayoutConstraint.activate([
                // Header pinned to the top safe area.
                headerContainer.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
                headerContainer.leadingAnchor.constraint(equalTo: view.leadingAnchor),
                headerContainer.trailingAnchor.constraint(equalTo: view.trailingAnchor),
                // Top padding balances the gap below the title (row bottom + the 16pt scroll inset), so the
                // title reads as vertically centered between the sheet's top edge and the content/divider.
                header.topAnchor.constraint(equalTo: headerContainer.topAnchor, constant: 16),
                header.leadingAnchor.constraint(equalTo: headerContainer.leadingAnchor, constant: 16),
                header.trailingAnchor.constraint(equalTo: headerContainer.trailingAnchor, constant: -16),
                header.bottomAnchor.constraint(equalTo: headerContainer.bottomAnchor),

                // Scroll area between header and bottom bar.
                scrollView.topAnchor.constraint(equalTo: headerContainer.bottomAnchor),
                scrollView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
                scrollView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
                scrollView.bottomAnchor.constraint(equalTo: bottomBar.topAnchor),

                rootStack.topAnchor.constraint(equalTo: scrollView.contentLayoutGuide.topAnchor, constant: 16),
                rootStack.bottomAnchor.constraint(equalTo: scrollView.contentLayoutGuide.bottomAnchor, constant: -16),
                rootStack.leadingAnchor.constraint(equalTo: scrollView.contentLayoutGuide.leadingAnchor, constant: 16),
                rootStack.trailingAnchor.constraint(equalTo: scrollView.contentLayoutGuide.trailingAnchor, constant: -16),
                // Content width follows the frame width (vertical-only scrolling); also pins the
                // content guide's horizontal extent, which would otherwise be ambiguous.
                rootStack.widthAnchor.constraint(equalTo: scrollView.frameLayoutGuide.widthAnchor, constant: -32),

                // Bottom bar pinned to the bottom safe area (footer hugs the bottom).
                bottomBar.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 16),
                bottomBar.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -16),
                bottomBar.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor, constant: -4),
            ])

            assembleRootStack()
        }

        /// Assembles the ordered scroll column into `rootStack`: the home page then the new-card
        /// subpage (only one visible at a time; navigation toggles `isHidden`).
        ///
        /// Home page (`homeStack`): express (if available) · saved-card list (if any) · "New card"
        /// entry row — always present so a card can be added even with no saved cards. New-card
        /// subpage (`newCardStack`): card form · "Save this card" · address. The CTA / notice /
        /// footer live in the fixed `bottomBar`, not here.
        private func assembleRootStack() {
            homeStack.axis = .vertical
            homeStack.spacing = 16
            buildHomeStack()
            rootStack.addArrangedSubview(homeStack)

            buildNewCardStack()
            rootStack.addArrangedSubview(newCardStack)

            allSavedCardsStack.axis = .vertical
            allSavedCardsStack.spacing = 16
            allSavedCardsStack.isHidden = true
            rootStack.addArrangedSubview(allSavedCardsStack)
        }

        /// Builds the home page: a collapsed saved-card summary (if any) + "New card" entry, with the
        /// express row (if available) first for `.top` and last for `.bottom`.
        private func buildHomeStack() {
            let express = makeExpressView()
            expressView = express

            if appearance.expressPosition != .bottom, let express {
                homeStack.addArrangedSubview(express)
            }

            if !savedCards.isEmpty {
                // Default selection: pre-select the first usable card so Pay is immediately available.
                selectedSavedCardId = defaultSavedCardId
                let summary = makeSavedCardSummary()
                savedCardSummary = summary
                homeStack.addArrangedSubview(summary)
            }

            if cardAvailable {
                let entry = makeNewCardEntryRow()
                newCardEntryRow = entry
                homeStack.addArrangedSubview(entry)
            }

            if appearance.expressPosition == .bottom, let express {
                homeStack.addArrangedSubview(express)
            }
        }

        /// Builds the new-card subpage: card form + optional save toggle + address forms.
        private func buildNewCardStack() {
            let topDivider = makeNewCardTopDivider()
            newCardStack.addArrangedSubview(topDivider)
            // A little more breathing room between the top divider and the first section title.
            newCardStack.setCustomSpacing(20, after: topDivider)

            let entry = NewCardEntryView(
                appearance: appearance, localize: localize, localeCode: localeCode, sessionId: session.id,
                cardBrandItems: cardBrandItems, cardRuleSet: cardRuleSet, cardBinService: cardBinService,
                cardRulesService: cardRulesService, billingMode: billingMode, shippingMode: shippingMode,
                addressService: addressService, cardOnFileEnabled: cardOnFileEnabled,
                saveCardByDefault: saveCardByDefault, scanPresenter: { [weak self] in self })
            newCardEntry = entry
            newCardStack.addArrangedSubview(entry)
        }

        // MARK: - Component factories

        /// Builds the collapsed home saved-card summary: a single `SavedCardRow` for the currently
        /// selected card (border-highlighted), plus a trailing "View more" affordance (so the full list,
        /// where cards can be managed, is one tap away).
        ///
        /// Tapping the summary card itself does nothing (it is already the selected card); only the
        /// explicit "View more" affordance opens the full list page.
        private func makeSavedCardSummary() -> UIView {
            let stack = UIStackView()
            stack.axis = .vertical
            stack.spacing = 8

            let selectedId = selectedSavedCardId ?? defaultSavedCardId
            if let card = savedCards.first(where: { $0.id == selectedId }) ?? savedCards.first {
                let row = SavedCardRow(
                    appearance: appearance, card: card, expiredText: expiredText(for: card),
                    logoLoader: logoLoader, deleteLabel: localize("sunbay.cof.delete"))
                // Every card expired: show the first one, dimmed and not selected (Pay stays hidden).
                row.setSelected(!row.isExpired)
                row.presentAsStaticSummary()
                // The drill-in lives on the card row itself: the trailing expiry is replaced by a
                // tappable "View more ›" that opens the full list (shown for any number of cards).
                row.showViewMoreInsteadOfExpiry(title: localize("sunbay.cof.viewMore")) { [weak self] in
                    self?.showAllSavedCards()
                }
                viewMoreAffordance = row.viewMoreControl
                stack.addArrangedSubview(row)
            } else {
                viewMoreAffordance = nil
            }
            return stack
        }

        /// Builds the express (wallet) view for the home page, or nil when unavailable.
        ///
        /// Shown only when the session allows Apple Pay and `expressPosition != .off`. It lives in the
        /// home page's `homeStack` (first for `.top`, last for `.bottom`), so it never appears on the
        /// new-card subpage.
        private func makeExpressView() -> ExpressCheckoutView? {
            guard appearance.expressPosition != .off, applePayVisible, session.methods.contains(.applePay) else {
                return nil
            }
            // Three-factor availability (design §7.4): backend allows ∩ device capable ∩ merchant id.
            if let walletAuthorizer {
                let availability = ApplePayAvailability.evaluate(
                    session: session, hiddenByFilter: !applePayVisible, authorizer: walletAuthorizer,
                    merchantId: walletMerchantId)
                if !availability.missing.isEmpty { onWalletParamsInvalid?(availability.missing) }
                guard availability.available else { return nil }
            }
            let express = ExpressCheckoutView(
                appearance: appearance,
                // `.bottom`: the row follows the "New card" entry, so the divider sits above the button.
                dividerPlacement: appearance.expressPosition == .bottom ? .above : .below,
                // The "Or pay using" divider only makes sense when other methods share the page. Today
                // that is the card area; add future non-wallet methods to `hasNonExpressMethods`.
                showsDivider: hasNonExpressMethods)
            express.setOrPayUsingText(localize("sunbay.sheet.orPayUsing"))
            express.onApplePayTapped = { [weak self] in
                self?.handleApplePayTapped()
            }
            return express
        }

        /// Builds the "New card" entry row for the home page: a card icon + localized title + chevron
        /// that opens the independent new-card subpage. Always present on the home page (so a card can
        /// be added even with no saved cards).
        private func makeNewCardEntryRow() -> UIView {
            let container = UIView()
            container.backgroundColor = appearance.componentBackground
            container.layer.cornerRadius = appearance.cornerRadius
            container.layer.borderWidth = max(appearance.borderWidth, 1)
            container.layer.borderColor = appearance.border.cgColor

            // SF Symbols carry baseline-based alignment insets that shift them off the label's center;
            // zero them and size the glyph from the label font so icon + title share one optical center.
            let symbolConfig = UIImage.SymbolConfiguration(font: appearance.cardFieldFont, scale: .medium)
            func centeredSymbol(_ name: String) -> UIImage? {
                UIImage(systemName: name, withConfiguration: symbolConfig)?.withAlignmentRectInsets(.zero)
            }
            let icon = UIImageView(image: centeredSymbol("creditcard"))
            icon.tintColor = appearance.primary
            icon.contentMode = .scaleAspectFit
            icon.setContentHuggingPriority(.required, for: .horizontal)
            icon.translatesAutoresizingMaskIntoConstraints = false

            let title = UILabel()
            title.text = localize("sunbay.cof.newPaymentMethod")
            title.font = appearance.cardFieldFont
            title.textColor = appearance.text
            title.translatesAutoresizingMaskIntoConstraints = false

            let chevron = UIImageView(image: centeredSymbol("chevron.right"))
            chevron.tintColor = appearance.textSecondary
            chevron.contentMode = .scaleAspectFit
            chevron.setContentHuggingPriority(.required, for: .horizontal)
            chevron.translatesAutoresizingMaskIntoConstraints = false

            let stack = UIStackView(arrangedSubviews: [icon, title, chevron])
            stack.axis = .horizontal
            stack.alignment = .center
            stack.spacing = 12
            stack.translatesAutoresizingMaskIntoConstraints = false
            container.addSubview(stack)

            NSLayoutConstraint.activate([
                stack.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 12),
                stack.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -12),
                stack.topAnchor.constraint(equalTo: container.topAnchor, constant: 12),
                stack.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -12),
                icon.widthAnchor.constraint(equalToConstant: 24),
                icon.heightAnchor.constraint(equalToConstant: 24),
                chevron.widthAnchor.constraint(equalToConstant: 16),
                chevron.heightAnchor.constraint(equalToConstant: 24),
                container.heightAnchor.constraint(greaterThanOrEqualToConstant: 52),
            ])

            container.isAccessibilityElement = true
            container.accessibilityTraits = .button
            container.accessibilityLabel = title.text
            container.addGestureRecognizer(
                UITapGestureRecognizer(target: self, action: #selector(handleNewCardEntryTap)))
            return container
        }

        @objc private func handleBackgroundTap() {
            view.endEditing(true)
        }

        @objc private func handleNewCardEntryTap() {
            showNewCardSubpage()
        }

        /// The Apple Pay row forwards a tap: run the PassKit authorization, then confirm the token.
        ///
        /// A pre-staged token (test hook) is confirmed directly. Otherwise the injected
        /// `walletAuthorizer` presents the system sheet; an authorization → `.confirmWallet`
        /// (authorization success ≠ payment success; the outcome comes back via `applyOutcome`).
        /// A user cancel leaves the sheet as-is; an authorization failure shows the inline error.
        /// The token flows only into `didRequest` and is never logged or stored (§5).
        private func handleApplePayTapped() {
            if let token = pendingWalletToken {
                handleConfirmWallet(token: token)
                return
            }
            guard let walletAuthorizer, let merchantId = walletMerchantId,
                  !isAuthorizingWallet,
                  !stateMachine.state.isLockedAgainstNewConfirm
            else { return }

            isAuthorizingWallet = true
            notice.hide()
            let amount = session.amount
            let merchantName = session.merchantName
            let params = session.applePayParams
            // The flags say whether the SDK shows a form for that kind right now; the same flags go to `confirmWallet`.
            let billingFormShown = newCardEntry?.billingFormShown ?? false
            let shippingFormShown = newCardEntry?.shippingFormShown ?? false
            let walletContacts = walletContacts
            Task { @MainActor [weak self] in
                do {
                    let contacts = await walletContacts?(billingFormShown, shippingFormShown)
                        ?? WalletContactRequest(billing: false, shipping: false)
                    // Each authorized token is confirmed while the Apple Pay sheet stays open; the
                    // outcome is applied to this content through the normal `applyOutcome` path.
                    _ = try await walletAuthorizer.authorize(
                        amount: amount, merchantId: merchantId, merchantName: merchantName,
                        params: params, contacts: contacts
                    ) { [weak self] authorization in
                        guard let self else { return .canceled }
                        return await self.confirmWalletAwaitingOutcome(
                            authorization, billingFormShown: billingFormShown, shippingFormShown: shippingFormShown)
                    }
                    self?.isAuthorizingWallet = false
                } catch {
                    guard let self else { return }
                    self.isAuthorizingWallet = false
                    if let checkoutError = error as? CheckoutError, checkoutError.code == "WALLET_CANCELED" {
                        return
                    }
                    let checkoutError = (error as? CheckoutError) ?? CheckoutError(
                        code: "WALLET_AUTH_FAILED",
                        message: "Apple Pay authorization failed.",
                        category: .runtime,
                        traceId: nil
                    )
                    self.notice.show(message: self.localizedFailure(checkoutError), severity: .error)
                    self.reportContentHeightIfChanged()
                }
            }
        }

        /// Stages a wallet token to be confirmed on the next Apple Pay tap (container / test hook).
        func stageWalletToken(_ token: Data) {
            pendingWalletToken = token
        }

        /// Starts a wallet confirm (processing + `didRequest`) and suspends until `applyOutcome`
        /// delivers its outcome, which the Apple Pay sheet then reflects.
        ///
        /// When a confirm must not start (one already in flight, or locked while reconciling) nothing
        /// is submitted and a `.failed` outcome is returned so the system sheet shows a failure.
        private func confirmWalletAwaitingOutcome(
            _ authorization: WalletAuthorization, billingFormShown: Bool, shippingFormShown: Bool
        ) async -> CheckoutOutcome {
            guard delegate != nil, beginProcessing() else {
                return .failed(
                    txnId: nil,
                    error: CheckoutError(
                        code: "WALLET_CONFIRM_REJECTED",
                        message: "A payment is already being confirmed.",
                        category: .runtime,
                        traceId: nil
                    )
                )
            }
            return await withCheckedContinuation { continuation in
                walletOutcomeContinuation = continuation
                delegate?.content(
                    self,
                    didRequest: .confirmWallet(
                        authorization, billingFormShown: billingFormShown, shippingFormShown: shippingFormShown))
            }
        }

        /// Resumes a waiting in-sheet wallet confirm (no-op when none is waiting).
        private func resumeWalletOutcome(_ outcome: CheckoutOutcome) {
            walletOutcomeContinuation?.resume(returning: outcome)
            walletOutcomeContinuation = nil
        }

        override func viewDidDisappear(_ animated: Bool) {
            super.viewDidDisappear(animated)
            // The sheet went away while a wallet confirm was still waiting (no outcome will arrive):
            // a payment may have been submitted, so release the Apple Pay sheet as `unknown`
            // (→ success status, closes the sheet without inviting a double charge).
            if isBeingDismissed || parent?.isBeingDismissed == true {
                resumeWalletOutcome(.unknown(sessionId: session.id))
            }
        }

        /// Builds a container holding a full-width hairline for the top of the new-card subpage.
        ///
        /// The subpage content is inset 16pt by `rootStack`; this divider escapes that inset by
        /// extending its line 16pt past each side of its container (back to the sheet edges), so it
        /// reads like the header separator but belongs to this page only. It references only its own
        /// subview, so there is no cross-hierarchy constraint timing issue.
        private func makeNewCardTopDivider() -> UIView {
            let container = UIView()
            container.translatesAutoresizingMaskIntoConstraints = false

            let line = UIView()
            line.backgroundColor = appearance.border
            line.translatesAutoresizingMaskIntoConstraints = false
            container.addSubview(line)

            NSLayoutConstraint.activate([
                container.heightAnchor.constraint(equalToConstant: 0.5),
                line.topAnchor.constraint(equalTo: container.topAnchor),
                line.bottomAnchor.constraint(equalTo: container.bottomAnchor),
                // Extend 16pt past each side (cancelling rootStack's 16pt inset) to reach the sheet edges.
                line.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: -16),
                line.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: 16),
            ])
            return container
        }

        // MARK: - Header / navigation

        private func configureHeader() {
            applyHomeHeaderCopy()
            header.onClose = { [weak self] in
                guard let self else { return }
                // Belt and braces: ignore programmatic / accessibility activation while a payment is
                // in flight or succeeding (the button itself is also disabled then).
                switch self.stateMachine.state {
                case .processing, .succeeded: return
                default: break
                }
                self.delegate?.contentDidRequestCancel(self)
            }
            header.onBack = { [weak self] in
                self?.showHome()
            }
            header.onAction = { [weak self] in
                self?.toggleManageMode()
            }
        }

        private func configureInitialNavigation() {
            // The home page is always the root; the new-card form is reached by tapping "New card".
            showHome(animated: false)
        }

        /// Shows the home page (express + collapsed saved-card summary + "New card" entry); hides the
        /// new-card subpage. No back button (home is the root). The title returns to the pay title.
        /// When saved cards exist, the home summary reflects the current selection (defaulting to the
        /// first card) so Pay shows a valid default.
        private func showHome(animated: Bool = true) {
            guard !stateMachine.state.isLockedAgainstNewConfirm else { return }
            if !savedCards.isEmpty, selectedSavedCardId == nil {
                selectedSavedCardId = defaultSavedCardId
            }
            exitManageMode()
            rebuildSavedCardSummary()
            performPageSwitch(direction: .backward, animated: animated) {
                isShowingNewCard = false
                isShowingAllSavedCards = false
                homeStack.isHidden = false
                newCardStack.isHidden = true
                allSavedCardsStack.isHidden = true
            }
            performHeaderSwitch(animated: animated) {
                self.header.setBackVisible(false)
                self.header.setCloseVisible(true)
                self.header.setActionTitle(nil)
                self.applyHomeHeaderCopy()
            }
            notice.hide()
            refreshConfirmButtonState()
            reportContentHeightIfChanged()
        }

        /// The first usable (non-expired) saved card, or nil when every card is expired.
        private var defaultSavedCardId: String? { selection.defaultId }

        /// The localized "Expired" label for an expired card, or nil when the card is usable.
        private func expiredText(for card: SavedCard) -> String? {
            selection.isExpired(card) ? localize("sunbay.cof.expired") : nil
        }

        /// Rebuilds the home saved-card summary in place so it reflects the current `selectedSavedCardId`
        /// ; when no saved cards remain the summary is removed.
        private func rebuildSavedCardSummary() {
            guard let old = savedCardSummary else { return }
            if savedCards.isEmpty {
                homeStack.removeArrangedSubview(old)
                old.removeFromSuperview()
                savedCardSummary = nil
                viewMoreAffordance = nil
                return
            }
            let fresh = makeSavedCardSummary()
            savedCardSummary = fresh
            if let index = homeStack.arrangedSubviews.firstIndex(of: old) {
                homeStack.insertArrangedSubview(fresh, at: index)
            }
            homeStack.removeArrangedSubview(old)
            old.removeFromSuperview()
        }

        /// Opens the full saved-card list page ("View more"): a forward page switch to the complete
        /// `SavedCardListView`, with the header showing the "Saved cards" title and a back button. The
        /// list reflects the current selection. Picking a row selects it and returns home; the back
        /// button returns home keeping the current selection.
        private func showAllSavedCards() {
            guard !stateMachine.state.isLockedAgainstNewConfirm, !savedCards.isEmpty else { return }
            if savedCardList == nil {
                let list = makeFullSavedCardList()
                savedCardList = list
                allSavedCardsStack.addArrangedSubview(list)
            }
            savedCardList?.selectedPaymentMethodId = selectedSavedCardId
            performPageSwitch(direction: .forward, animated: true) {
                isShowingNewCard = false
                isShowingAllSavedCards = true
                homeStack.isHidden = true
                newCardStack.isHidden = true
                allSavedCardsStack.isHidden = false
            }
            performHeaderSwitch(animated: true) {
                self.header.setBackVisible(true)
                self.header.setCloseVisible(false)
                self.header.setTitle(self.localize("sunbay.sheet.savedCards"))
                self.header.setActionTitle(self.localize("sunbay.cof.manage"))
            }
            notice.hide()
            refreshConfirmButtonState()
            reportContentHeightIfChanged()
        }

        /// Builds the full saved-card list for the "View more" page. Picking a row records the
        /// selection, refreshes the home summary, and returns home (picker flow); it never submits.
        private func makeFullSavedCardList() -> SavedCardListView {
            let list = SavedCardListView(
                appearance: appearance, cards: savedCards, logoLoader: logoLoader,
                deleteLabel: localize("sunbay.cof.delete")
            ) { [weak self] card in
                self?.expiredText(for: card)
            }
            list.onDelete = { [weak self] id in
                self?.confirmDelete(id)
            }
            list.onSelect = { [weak self] paymentMethodId in
                guard let self else { return }
                self.selectedSavedCardId = paymentMethodId
                self.rebuildSavedCardSummary()
                self.refreshConfirmButtonState()
                self.showHome()
            }
            return list
        }

        // MARK: - Saved-card management

        /// Toggles manage mode on the full saved-card list page ("Manage" <-> "Done").
        private func toggleManageMode() {
            guard isShowingAllSavedCards, !stateMachine.state.isLockedAgainstNewConfirm else { return }
            isManagingSavedCards.toggle()
            savedCardList?.setManaging(isManagingSavedCards)
            header.setActionTitle(localize(isManagingSavedCards ? "sunbay.cof.done" : "sunbay.cof.manage"))
            reportContentHeightIfChanged()
        }

        private func exitManageMode() {
            isManagingSavedCards = false
            savedCardList?.setManaging(false)
        }

        /// Asks the user to confirm deleting a saved card.
        private func confirmDelete(_ id: String) {
            guard !stateMachine.state.isLockedAgainstNewConfirm, !deletingCardIds.contains(id),
                  presentedViewController == nil,
                  let card = savedCards.first(where: { $0.id == id }) else { return }
            let description = "\(card.brand.uppercased()) •••• \(card.last4)"
            let alert = UIAlertController(
                title: localize("sunbay.cof.deleteConfirmTitle"),
                message: localize("sunbay.cof.deleteConfirmMessage").replacingOccurrences(of: "%@", with: description),
                preferredStyle: .alert)
            alert.addAction(UIAlertAction(title: localize("sunbay.sheet.cancel"), style: .cancel))
            alert.addAction(UIAlertAction(title: localize("sunbay.cof.delete"), style: .destructive) { [weak self] _ in
                self?.performDelete(id)
            })
            present(alert, animated: true)
        }

        /// Requests the delete through the delegate; removes the card on success, keeps it and shows a
        /// notice on failure.
        private func performDelete(_ id: String) {
            guard selection.beginDelete(id) else { return }
            savedCardList?.setDeleting(id, true)
            header.setBackEnabled(false)
            header.setActionEnabled(false)
            guard let delegate else {
                finishDelete(id, result: .failure(CheckoutErrors.cardDeleteUnsupported()))
                return
            }
            delegate.content(self, didRequestDeleteSavedCard: id) { [weak self] result in
                self?.finishDelete(id, result: result)
            }
        }

        private func finishDelete(_ id: String, result: Result<Void, CheckoutError>) {
            selection.endDelete(id)
            if deletingCardIds.isEmpty, !stateMachine.state.isLockedAgainstNewConfirm {
                header.setBackEnabled(true)
                header.setActionEnabled(true)
            }
            switch result {
            case .success:
                removeSavedCard(id)
            case .failure:
                savedCardList?.setDeleting(id, false)
                // Only on the list page: if the user already left, a delete error would be out of context.
                if isShowingAllSavedCards {
                    ToastView.show(
                        localize("sunbay.cof.deleteFailed"), appearance: appearance, in: view, above: bottomBar)
                }
            }
        }

        /// Drops a deleted card from the model and the UI; clears the selection if it was selected and
        /// returns home when no cards remain.
        private func removeSavedCard(_ id: String) {
            let wasSelected = selectedSavedCardId == id
            selection.remove(id)
            savedCardList?.removeCard(id)
            if wasSelected {
                savedCardList?.selectedPaymentMethodId = nil
            }
            if savedCards.isEmpty, let list = savedCardList {
                allSavedCardsStack.removeArrangedSubview(list)
                list.removeFromSuperview()
                savedCardList = nil
            }
            if isShowingAllSavedCards {
                if savedCards.isEmpty {
                    showHome()
                } else {
                    refreshConfirmButtonState()
                    reportContentHeightIfChanged()
                }
            } else {
                // The user left the list while the delete was in flight: keep the home summary and the
                // default selection consistent without navigating (the new-card page keeps no selection).
                if !isShowingNewCard, selectedSavedCardId == nil {
                    selectedSavedCardId = defaultSavedCardId
                }
                rebuildSavedCardSummary()
                refreshConfirmButtonState()
                reportContentHeightIfChanged()
            }
        }

        /// Applies the home-page header title: the custom title, or the localized default. Only the
        /// home page is configurable.
        private func applyHomeHeaderCopy() {
            header.setTitle(homeTitle ?? localize("sunbay.sheet.payTitle"))
        }

        /// Applies a page switch with the shared forward/backward transition (see `PageTransition`).
        /// Any future in-sheet page change should go through here.
        private func performPageSwitch(
            direction: PageDirection, animated: Bool, change: () -> Void
        ) {
            // The fields on the page being left are about to be hidden; hidden views keep first
            // responder status, which would leave the keyboard up on the next page.
            view.endEditing(true)
            PageTransition.perform(
                in: scrollView, content: rootStack, direction: direction,
                animated: animated && appearance.pageTransitionsEnabled, change: change)
        }

        /// Cross-dissolves the header (title + back button) in step with a page switch.
        private func performHeaderSwitch(animated: Bool, change: @escaping () -> Void) {
            PageTransition.crossDissolve(
                header, animated: animated && appearance.pageTransitionsEnabled, change: change)
        }

        /// Shows the independent new-card subpage (card form + address + Pay; no express). A back
        /// button returns to the home page. Entering clears the saved-card selection; returning home
        /// re-applies the first-card default.
        private func showNewCardSubpage(animated: Bool = true) {
            guard !stateMachine.state.isLockedAgainstNewConfirm else { return }
            performPageSwitch(direction: .forward, animated: animated) {
                isShowingNewCard = true
                isShowingAllSavedCards = false
                homeStack.isHidden = true
                newCardStack.isHidden = false
                allSavedCardsStack.isHidden = true
            }
            exitManageMode()
            // Clear the selection while on the subpage; `showHome()` re-applies the first-card default.
            selectedSavedCardId = nil
            performHeaderSwitch(animated: animated) {
                self.header.setBackVisible(true)
                self.header.setCloseVisible(false)
                self.header.setTitle(self.localize("sunbay.sheet.newCard"))
                self.header.setActionTitle(nil)
            }
            notice.hide()
            refreshConfirmButtonState()
            reportContentHeightIfChanged()
        }

        // MARK: - Confirm button wiring

        private func configureConfirmButton() {
            confirmButton.setTitle(payTitle())
            confirmButton.onTap = { [weak self] in
                self?.handlePayTapped()
            }
            newCardEntry?.onEditingChanged = { [weak self] in
                self?.refreshConfirmButtonState()
            }
        }

        /// Routes a Pay tap to the right confirm path based on the current page / selection.
        ///
        /// On the home page with a selected saved card → confirm that saved card. On the new-card
        /// subpage → confirm the entered card. (The button is only visible/enabled when one of these
        /// is submittable, per `refreshConfirmButtonState`.)
        private func handlePayTapped() {
            if isShowingNewCard {
                handleConfirmNewCard()
            } else {
                guard let id = selectedSavedCardId else { return }
                handleConfirmSavedCard(paymentMethodId: id)
            }
        }

        /// The locale used to format the amount: the host-configured locale when set, otherwise the
        /// device locale. Keeps the Pay-button amount consistent with `CheckoutConfiguration.locale`.
        private var resolvedLocale: Locale {
            guard let localeCode else { return .current }
            return Locale(identifier: localeCode)
        }

        /// The CTA title: the localized `Pay %@` with the session amount formatted via `AmountFormatter`.
        private func payTitle() -> String {
            let amountString = AmountFormatter().string(from: session.amount, locale: resolvedLocale)
            let template = localize("sunbay.sheet.payAmount")
            if template.contains("%@") {
                return template.replacingOccurrences(of: "%@", with: amountString)
            }
            // Fallback when the key is unmapped (resolver returns the key unchanged under `{ $0 }`).
            return "\(localize("sunbay.sheet.pay")) \(amountString)"
        }

        // MARK: - Content height reporting

        /// Reports the preferred TOTAL sheet content height to the delegate when it changes.
        ///
        /// Sums the real chrome so the container's explicit sheet height fits the whole sheet:
        /// the top safe-area inset, the fixed header (full width), the scroll content (`rootStack`,
        /// measured at `width - 32` plus its 16 + 16 scroll insets), the fixed bottom bar (measured
        /// at `width - 32` plus its 4 pt bottom constant), and the bottom safe-area inset. The result
        /// is clamped by `Appearance.sheetSizing`; any overflow is absorbed by the scroll area.
        /// Called from `viewDidLayoutSubviews` and explicitly after page navigation.
        private func reportContentHeightIfChanged() {
            let width = view.bounds.width
            guard width > 0 else { return }
            let inset: CGFloat = 16
            let fitting = UIView.layoutFittingCompressedSize.height
            func fit(_ target: UIView, width: CGFloat) -> CGFloat {
                target.systemLayoutSizeFitting(
                    CGSize(width: width, height: fitting),
                    withHorizontalFittingPriority: .required,
                    verticalFittingPriority: .fittingSizeLevel
                ).height
            }
            let headerHeight = fit(headerContainer, width: width)
            let contentHeight = fit(rootStack, width: width - 2 * inset)
            let bottomHeight = fit(bottomBar, width: width - 2 * inset)
            let scrollInsets: CGFloat = 16 + 16
            let bottomBarMargin: CGFloat = 4
            let height = view.safeAreaInsets.top + headerHeight + scrollInsets + contentHeight
                + bottomHeight + bottomBarMargin + view.safeAreaInsets.bottom
            guard abs(height - lastReportedHeight) > 0.5 else { return }
            lastReportedHeight = height
            delegate?.content(self, didUpdateContentHeight: height)
        }
    }

    extension CheckoutContentViewController: UIGestureRecognizerDelegate {
        func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldReceive touch: UITouch) -> Bool {
            KeyboardDismissal.shouldHandleTap(on: touch.view)
        }
    }
#endif
