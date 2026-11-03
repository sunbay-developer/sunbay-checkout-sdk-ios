#if canImport(UIKit)
    import UIKit

    /// The host-agnostic checkout content (spec §3, Task 8): it composes the Task 6/7 components into a
    /// scrolling column, owns the visible `CheckoutStateMachine`, and talks to the outside world only
    /// through `CheckoutContentDelegate`. It never references the container or `CheckoutController`.
    ///
    /// ## Composition (top → bottom)
    /// header · [express row if `.top`] · (saved-card list OR new-card subpage) · [express row if
    /// `.bottom`] · confirm button · inline notice · footer. The new-card subpage carries the card
    /// form, an optional "Save this card" toggle (COF), and the billing / shipping address forms.
    ///
    /// ## Navigation (option A — self-managed)
    /// When saved cards exist the root shows the list; tapping "New card" switches to the new-card
    /// subpage and makes the header back button visible; back returns to the list. With no saved cards
    /// the new-card subpage is the root (no back button). All of this lives inside this VC; the
    /// container is never consulted.
    ///
    /// ## State wiring (spec §3.2)
    /// A confirm (pay with new card / tap a saved card / Apple Pay authorized) moves the machine to
    /// `.processing`, disables inputs, drives the `ConfirmButton` spinner, emits
    /// `delegate.didChangeProcessing(true)` + `didChangeState(.processing)`, then emits
    /// `delegate.content(didRequest:)`. The container drives the controller and feeds the result back
    /// via `applyOutcome(_:)`, which runs the machine and reacts: `.autoClose` animates success then
    /// `didFinishWith`; `.showError` shows the inline error and re-enables; `.showInfoNotice` shows a
    /// neutral notice and returns to editing. The processing phase is held for at least
    /// `ConfirmButton.minimumFlightTime` before the terminal UI is applied, to avoid a flicker.
    ///
    /// iOS-only: gated by `#if canImport(UIKit)`; does not compile under the macOS host (`swift test`).
    final class CheckoutContentViewController: UIViewController {
        // MARK: - Delegate

        /// The content boundary. The container (Task 9) implements it; held weakly to avoid a cycle.
        weak var delegate: CheckoutContentDelegate?

        // MARK: - Injected dependencies

        private let session: CheckoutSession
        private let savedCards: [SavedCard]
        private let appearance: ResolvedAppearance
        private let localize: (String) -> String
        private let billingMode: Appearance.AddressCollectionMode
        private let shippingMode: Appearance.AddressCollectionMode
        private let addressService: any AddressMetadataService

        // MARK: - State

        private var stateMachine = CheckoutStateMachine()

        /// When a confirm started, so `applyOutcome` can hold the processing phase for at least
        /// `ConfirmButton.minimumFlightTime` before applying a terminal result (avoids a flicker).
        private var processingStartedAt: Date?

        /// The pending Apple Pay wallet token (set when the probe/authorization yields one). The real
        /// PassKit authorization is the container's job; this VC just forwards a token when asked.
        private var pendingWalletToken: Data?

        // MARK: - Components

        private lazy var header = SheetHeaderView(appearance: appearance, localize: localize)
        private lazy var cardForm = CardFormView(appearance: appearance, localize: localize)
        private lazy var confirmButton = ConfirmButton(appearance: appearance)
        private lazy var notice = InlineNoticeView(appearance: appearance)
        private lazy var footer = CheckoutFooterView(appearance: appearance, localize: localize)

        private var savedCardList: SavedCardListView?
        private var expressView: ExpressCheckoutView?

        /// The "Save this card" (COF consent) toggle, shown only when COF is enabled on the session.
        private var saveCardSwitch: UISwitch?

        private var billingAddressView: UIView?
        private var shippingAddressView: UIView?
        private var shippingSameAsBillingSwitch: UISwitch?
        private var shippingContainer: UIStackView?

        // MARK: - Layout containers

        private let scrollView = UIScrollView()
        private let rootStack = UIStackView()
        /// The subpage that holds new-card entry (card form + save toggle + address). Hidden while the
        /// saved-card list is shown.
        private let newCardStack = UIStackView()

        /// Whether the saved-card list (vs the new-card subpage) is currently visible.
        private var isShowingSavedList = false

        private var lastReportedHeight: CGFloat = 0

        // MARK: - Init

        /// Creates the content VC.
        ///
        /// - Parameters:
        ///   - session: The loaded checkout session (amount / merchant / methods).
        ///   - savedCards: The saved cards to list (empty when COF is unavailable).
        ///   - appearance: The resolved appearance tokens.
        ///   - localize: The localization closure for all copy.
        ///   - billingMode: The billing-address collection mode.
        ///   - shippingMode: The shipping-address collection mode.
        ///   - addressService: The address-metadata service (for the full address form).
        init(
            session: CheckoutSession,
            savedCards: [SavedCard],
            appearance: ResolvedAppearance,
            localize: @escaping (String) -> String,
            billingMode: Appearance.AddressCollectionMode,
            shippingMode: Appearance.AddressCollectionMode,
            addressService: any AddressMetadataService
        ) {
            self.session = session
            self.savedCards = savedCards
            self.appearance = appearance
            self.localize = localize
            self.billingMode = billingMode
            self.shippingMode = shippingMode
            self.addressService = addressService
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
            configureExpressIfNeeded()
            configureInitialNavigation()
            refreshConfirmButtonState()
        }

        override func viewDidLayoutSubviews() {
            super.viewDidLayoutSubviews()
            reportContentHeightIfChanged()
        }

        // MARK: - Public API

        /// The current internal view state (test / introspection readout).
        var currentViewState: CheckoutViewState { stateMachine.state }

        /// Test readout: whether the card form is currently interactive (re-enabled after a failure).
        var isCardFormInteractiveForTest: Bool { cardForm.isUserInteractionEnabled }

        /// Test readout: whether the primary CTA is interactive (enabled) right now. After a `.failed`
        /// outcome with a complete form this must be `true` so the user can retry (spec §3.1/§3.2) —
        /// the button is `isEnabled` only in its `.enabled` status, so this reflects the fix that moves
        /// the CTA off `.processing` on the `.failed`→editing transition.
        var isConfirmButtonEnabledForTest: Bool { confirmButton.isEnabled }

        /// Applies a confirm outcome: runs the state machine and drives the UI per spec §3.2.
        ///
        /// The processing phase is held for at least `ConfirmButton.minimumFlightTime` from the confirm
        /// tap before the terminal UI is applied, so a fast backend does not cause a spinner flicker.
        ///
        /// - Parameter outcome: The terminal / intermediate outcome from the confirm dispatch.
        func applyOutcome(_ outcome: CheckoutOutcome) {
            let elapsed = processingStartedAt.map { Date().timeIntervalSince($0) } ?? 0
            let remaining = max(0, ConfirmButton.minimumFlightTime - elapsed)

            guard remaining > 0 else {
                performApply(outcome)
                return
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + remaining) { [weak self] in
                self?.performApply(outcome)
            }
        }

        /// Runs the machine and reacts to its `StepResult`, emitting the state change.
        private func performApply(_ outcome: CheckoutOutcome) {
            let result = stateMachine.apply(outcome, localizedFailure: localizedFailure(_:))
            emitStateChange()

            switch result {
            case let .autoClose(finalOutcome):
                confirmButton.update(status: .succeeded, animated: true) { [weak self] in
                    guard let self else { return }
                    self.delegate?.content(self, didFinishWith: finalOutcome)
                }

            case let .showError(message):
                notice.show(message: message, severity: .error)
                returnToEditing()

            case .showInfoNotice:
                notice.show(message: localize("sunbay.notice.pending"), severity: .info)
                returnToEditing()

            case .stay:
                // e.g. canceled: let the caller handle dismissal; no visible change here.
                break
            }
        }

        // MARK: - Test seams

        /// Fills the card form with a valid test card (bypasses keystrokes).
        func fillCardForTest() {
            cardForm.setFieldsForTest(pan: "4242424242424242", expiry: "08/28", cvv: "123")
            refreshConfirmButtonState()
        }

        /// Simulates a confirm tap on the primary CTA (pay with the new card).
        func simulateTapPay() {
            handleConfirmNewCard()
        }

        // MARK: - Confirm handling

        /// Pay with the manually entered new card.
        private func handleConfirmNewCard() {
            guard let input = cardForm.cardInput else {
                cardForm.showFieldError(.number, message: localize("sunbay.card.invalid"))
                return
            }
            let save = saveCardSwitch?.isOn ?? false
            beginProcessing()
            delegate?.content(self, didRequest: .confirmNewCard(input, save: save))
        }

        /// Pay with a selected saved card (COF one-tap).
        private func handleConfirmSavedCard(paymentMethodId: String) {
            beginProcessing()
            delegate?.content(self, didRequest: .confirmSavedCard(paymentMethodId: paymentMethodId))
        }

        /// Confirm a wallet payment once a token has been obtained.
        private func handleConfirmWallet(token: Data) {
            beginProcessing()
            delegate?.content(self, didRequest: .confirmWallet(token: token))
        }

        /// Moves to the processing phase: machine, CTA spinner, disabled inputs, delegate notices.
        private func beginProcessing() {
            // Re-entrancy guard: a confirm already in flight must not be fired again, independent of the
            // UI enabled-state (a double-tap or a programmatic re-trigger).
            guard stateMachine.state != .processing else { return }
            notice.hide()
            cardForm.showFieldError(.number, message: nil)
            processingStartedAt = Date()
            stateMachine.beginProcessing()
            confirmButton.update(status: .processing, animated: false)
            setInputsEnabled(false)
            delegate?.content(self, didChangeProcessing: true)
            emitStateChange()
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
            let resolver = LocalizationResolver(explicitLocale: nil)
            return error.localizedDisplayMessage(using: resolver)
        }

        // MARK: - Enable / disable

        /// Enables or disables the editable inputs during / after processing.
        private func setInputsEnabled(_ enabled: Bool) {
            cardForm.isUserInteractionEnabled = enabled
            savedCardList?.isUserInteractionEnabled = enabled
            expressView?.isUserInteractionEnabled = enabled
            saveCardSwitch?.isEnabled = enabled
            billingAddressView?.isUserInteractionEnabled = enabled
            shippingContainer?.isUserInteractionEnabled = enabled
        }

        /// Updates the CTA enabled/disabled status from the current payment submittability.
        ///
        /// Safe to call while the machine is `.editing` **or** `.failed` — both are editable states
        /// where the user may (re)submit (spec §3.1 "failed … can return to editing for retry", §3.2
        /// "failed … stay open"). It must not clobber the CTA while a confirm is in flight
        /// (`.processing`) or during the success animation (`.succeeded`), so those are guarded out.
        private func refreshConfirmButtonState() {
            switch stateMachine.state {
            case .processing, .succeeded:
                return
            case .editing, .failed:
                break
            }
            // On the saved-card list the CTA is driven by selection; on the new-card subpage it tracks
            // card completeness. Keep it enabled on the list page (one-tap happens on row selection).
            if isShowingSavedList {
                confirmButton.update(status: .disabled, animated: false)
            } else {
                let complete = cardForm.cardInput != nil
                confirmButton.update(status: complete ? .enabled : .disabled, animated: false)
            }
        }

        // MARK: - Layout construction

        private func buildLayout() {
            scrollView.translatesAutoresizingMaskIntoConstraints = false
            view.addSubview(scrollView)

            rootStack.axis = .vertical
            rootStack.spacing = 16
            rootStack.translatesAutoresizingMaskIntoConstraints = false
            scrollView.addSubview(rootStack)

            newCardStack.axis = .vertical
            newCardStack.spacing = 16
            newCardStack.translatesAutoresizingMaskIntoConstraints = false

            NSLayoutConstraint.activate([
                scrollView.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
                scrollView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
                scrollView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
                scrollView.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor),

                rootStack.topAnchor.constraint(equalTo: scrollView.contentLayoutGuide.topAnchor, constant: 16),
                rootStack.bottomAnchor.constraint(equalTo: scrollView.contentLayoutGuide.bottomAnchor, constant: -16),
                rootStack.leadingAnchor.constraint(equalTo: scrollView.frameLayoutGuide.leadingAnchor, constant: 16),
                rootStack.trailingAnchor.constraint(equalTo: scrollView.frameLayoutGuide.trailingAnchor, constant: -16),
            ])

            assembleRootStack()
        }

        /// Assembles the ordered column into `rootStack`.
        private func assembleRootStack() {
            rootStack.addArrangedSubview(header)

            if appearance.expressPosition == .top {
                addExpressPlaceholder()
            }

            if !savedCards.isEmpty {
                let list = makeSavedCardList()
                savedCardList = list
                rootStack.addArrangedSubview(list)
            }

            buildNewCardStack()
            rootStack.addArrangedSubview(newCardStack)

            if appearance.expressPosition == .bottom {
                addExpressPlaceholder()
            }

            rootStack.addArrangedSubview(confirmButton)
            rootStack.addArrangedSubview(notice)
            rootStack.addArrangedSubview(footer)
        }

        /// Builds the new-card subpage: card form + optional save toggle + address forms.
        private func buildNewCardStack() {
            newCardStack.addArrangedSubview(cardForm)

            if session.cofEnabled {
                newCardStack.addArrangedSubview(makeSaveCardRow())
            }

            if let billing = makeAddressView(mode: billingMode) {
                billingAddressView = billing
                newCardStack.addArrangedSubview(makeSectionTitle("sunbay.address.billingTitle"))
                newCardStack.addArrangedSubview(billing)
            }

            if let shippingSection = makeShippingSection() {
                newCardStack.addArrangedSubview(shippingSection)
            }
        }

        // MARK: - Component factories

        private func makeSavedCardList() -> SavedCardListView {
            let list = SavedCardListView(appearance: appearance, localize: localize, cards: savedCards)
            list.onSelect = { [weak self] paymentMethodId in
                self?.handleConfirmSavedCard(paymentMethodId: paymentMethodId)
            }
            list.onTapNewCard = { [weak self] in
                self?.showNewCardSubpage()
            }
            return list
        }

        private func addExpressPlaceholder() {
            guard appearance.expressPosition != .off, session.methods.contains(.applePay) else { return }
            let express = ExpressCheckoutView(appearance: appearance)
            express.setOrPayUsingText(localize("sunbay.sheet.orPayUsing"))
            express.onApplePayTapped = { [weak self] in
                self?.handleApplePayTapped()
            }
            expressView = express
            rootStack.addArrangedSubview(express)
        }

        /// The Apple Pay row forwards a tap. When a token has already been staged (by the container /
        /// probe) it is confirmed immediately; otherwise nothing is emitted here — the container owns
        /// the PassKit authorization and calls back through the seam once a token exists.
        private func handleApplePayTapped() {
            guard let token = pendingWalletToken else { return }
            handleConfirmWallet(token: token)
        }

        /// Stages a wallet token to be confirmed on the next Apple Pay tap (container / test hook).
        func stageWalletToken(_ token: Data) {
            pendingWalletToken = token
        }

        private func makeSaveCardRow() -> UIView {
            let toggle = UISwitch()
            toggle.onTintColor = appearance.primary
            toggle.translatesAutoresizingMaskIntoConstraints = false
            saveCardSwitch = toggle

            let label = UILabel()
            label.text = localize("sunbay.sheet.saveThisCard")
            label.font = appearance.cardFieldFont
            label.textColor = appearance.text
            label.translatesAutoresizingMaskIntoConstraints = false

            let row = UIStackView(arrangedSubviews: [label, toggle])
            row.axis = .horizontal
            row.alignment = .center
            row.distribution = .fill
            return row
        }

        private func makeSectionTitle(_ key: String) -> UILabel {
            let label = UILabel()
            label.text = localize(key)
            label.font = appearance.sectionTitleFont
            label.textColor = appearance.text
            return label
        }

        /// Builds a billing/shipping address view for a collection mode, or nil if there is none.
        private func makeAddressView(mode: Appearance.AddressCollectionMode) -> UIView? {
            switch mode {
            case .simple:
                return SimpleAddressFormView(appearance: appearance, localize: localize)
            case .full:
                return DynamicAddressFormView(
                    appearance: appearance, localize: localize, service: addressService, locale: nil)
            }
        }

        /// Builds the shipping section: a title, a "same as billing" toggle, and the shipping form.
        private func makeShippingSection() -> UIView? {
            guard let shipping = makeAddressView(mode: shippingMode) else { return nil }
            shippingAddressView = shipping

            let title = makeSectionTitle("sunbay.address.shippingTitle")

            let toggleLabel = UILabel()
            toggleLabel.text = localize("sunbay.address.sameAsBilling")
            toggleLabel.font = appearance.cardFieldFont
            toggleLabel.textColor = appearance.text

            let toggle = UISwitch()
            toggle.onTintColor = appearance.primary
            toggle.isOn = true
            toggle.addTarget(self, action: #selector(handleSameAsBillingChanged), for: .valueChanged)
            shippingSameAsBillingSwitch = toggle

            let toggleRow = UIStackView(arrangedSubviews: [toggleLabel, toggle])
            toggleRow.axis = .horizontal
            toggleRow.alignment = .center

            let container = UIStackView(arrangedSubviews: [title, toggleRow, shipping])
            container.axis = .vertical
            container.spacing = 12
            shippingContainer = container

            // Default: "same as billing" is on, so the shipping form is hidden initially.
            shipping.isHidden = true
            return container
        }

        @objc private func handleSameAsBillingChanged() {
            let sameAsBilling = shippingSameAsBillingSwitch?.isOn ?? true
            shippingAddressView?.isHidden = sameAsBilling
        }

        // MARK: - Header / navigation

        private func configureHeader() {
            header.setTitle(localize("sunbay.sheet.payTitle"))
            header.onClose = { [weak self] in
                guard let self else { return }
                self.delegate?.contentDidRequestCancel(self)
            }
            header.onBack = { [weak self] in
                self?.showSavedList()
            }
        }

        private func configureInitialNavigation() {
            if savedCards.isEmpty {
                showNewCardSubpage(animated: false)
            } else {
                showSavedList(animated: false)
            }
        }

        private func showSavedList(animated: Bool = true) {
            guard !savedCards.isEmpty else { return }
            isShowingSavedList = true
            savedCardList?.isHidden = false
            newCardStack.isHidden = true
            header.setBackVisible(false)
            notice.hide()
            refreshConfirmButtonState()
        }

        private func showNewCardSubpage(animated: Bool = true) {
            isShowingSavedList = false
            savedCardList?.isHidden = true
            newCardStack.isHidden = false
            // Back button only when there is a list to return to.
            header.setBackVisible(!savedCards.isEmpty)
            notice.hide()
            refreshConfirmButtonState()
        }

        // MARK: - Confirm button wiring

        private func configureConfirmButton() {
            confirmButton.setTitle(payTitle())
            confirmButton.onTap = { [weak self] in
                self?.handleConfirmNewCard()
            }
            cardForm.onEditingChanged = { [weak self] in
                self?.refreshConfirmButtonState()
            }
        }

        /// The CTA title: the localized `Pay %@` with the session amount formatted via `AmountFormatter`.
        private func payTitle() -> String {
            let amountString = AmountFormatter().string(from: session.amount, locale: .current)
            let template = localize("sunbay.sheet.payAmount")
            if template.contains("%@") {
                return template.replacingOccurrences(of: "%@", with: amountString)
            }
            // Fallback when the key is unmapped (resolver returns the key unchanged under `{ $0 }`).
            return "\(localize("sunbay.sheet.pay")) \(amountString)"
        }

        private func configureExpressIfNeeded() {
            // Express is composed during `assembleRootStack`; nothing extra required here. Kept as a
            // hook so later availability gating (design §7.4) can live in one place.
        }

        // MARK: - Content height reporting

        /// Reports the preferred content height to the delegate when it changes (reserved for L2).
        private func reportContentHeightIfChanged() {
            let height = rootStack.systemLayoutSizeFitting(
                CGSize(width: view.bounds.width, height: UIView.layoutFittingCompressedSize.height)
            ).height
            guard abs(height - lastReportedHeight) > 0.5 else { return }
            lastReportedHeight = height
            delegate?.content(self, didUpdateContentHeight: height)
        }
    }
#endif
