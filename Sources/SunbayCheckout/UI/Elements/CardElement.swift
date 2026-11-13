#if canImport(UIKit)
    import UIKit

    /// Callbacks from a `CardElement` to the screen that hosts it.
    @MainActor
    public protocol CardElementDelegate: AnyObject {
        /// The element's content height changed (a saved card or the "New card" row was selected, an
        /// address form finished loading, an inline error appeared). Re-run your layout; with Auto Layout
        /// the element's `view` already updates its intrinsic height.
        func cardElementDidUpdateHeight(_ element: CardElement)

        /// The selected payment option changed (the user picked a saved card or the new-card form).
        /// `CheckoutElements.paymentOption` reflects the new selection. Optional; the default does nothing.
        func cardElementDidChangeSelection(_ element: CardElement)

        /// `CardElement.isComplete` flipped (the typed card became valid / invalid, or the selection
        /// changed between a saved card and the form). Use it to enable your own Pay button. Optional;
        /// the default does nothing.
        func cardElementDidChangeCompleteness(_ element: CardElement)
    }

    extension CardElementDelegate {
        public func cardElementDidChangeSelection(_ element: CardElement) {}
        public func cardElementDidChangeCompleteness(_ element: CardElement) {}
    }

    /// The bank-card component of `CheckoutElements`: the saved-card list (when card-on-file is on), a
    /// "New card" row and the inline new-card form (card fields, optional "save this card" checkbox,
    /// billing / shipping address forms).
    ///
    /// The merchant places `view` in its own layout and owns the Pay button; it calls
    /// `CheckoutElements.confirm()` to pay whatever this element has selected. There is exactly one
    /// `CardElement` per `CheckoutElements`: a second `makeCardElement(_:)` returns this same instance
    /// (its first configuration stays in effect).
    ///
    /// ## Initial height
    /// The delegate gets no initial height callback. After adding `view` to your layout, read
    /// `view.intrinsicContentSize` once (or let Auto Layout do it); `cardElementDidUpdateHeight(_:)` fires
    /// only for later changes.
    ///
    /// ## Composition
    /// With saved cards, the first usable one is selected and the form stays collapsed behind the
    /// "New card" row; expired cards are dimmed and cannot be selected. Without saved cards the form is
    /// shown directly.
    ///
    /// ## Precedence
    /// The backend decides whether an address is collected. The host's global switches
    /// (`Appearance.billingAddressEnabled` / `shippingAddressEnabled`, and the form style) may only turn a
    /// form off; `Configuration.billingAddress` / `shippingAddress` can only turn it off further
    /// (`.automatic` = follow the session and the global switch, `.off` = hide), never on. A host address
    /// already supplied through `CheckoutElements.Configuration` suppresses the form as in `PaymentSheet`.
    /// The global `PaymentMethodFilter` hiding `CARD` makes the element unavailable (zero-height view).
    ///
    /// ## Result and lock
    /// The element renders no failure / pending / unknown notices and no spinner: only inline field
    /// validation errors. Outcomes are reported by `confirm()`. While a payment is in flight all inputs
    /// are disabled (and the keyboard is dismissed); after `.failed` the form and selection stay so a retry
    /// works; on every terminal state (`.succeeded`, `.pending`, `.unknown`, `.canceled` by `close()`, an
    /// ended session) the typed values are cleared and the element stays disabled.
    ///
    /// ## Lifetime
    /// The element does not retain its `CheckoutElements`. If only the `CardElement` is retained and the
    /// group is released, the group's deinit closes the session, but the element is not locked or cleared
    /// (no pay path exists any more). Keep the group alive for as long as its components are on screen.
    ///
    /// ## Payment option image
    /// `CheckoutElements.paymentOption.image` may be `nil` until the brand logo has loaded; the host is
    /// not notified when it arrives, so read `paymentOption` again (for example from
    /// `cardElementDidChangeSelection`) if it needs the image. `paymentOption` is `nil` once the element
    /// has ended (a settled payment or an ended session), like `isComplete`.
    ///
    /// ## Security
    /// Card values stay inside the SDK's input fields until `confirm()` encrypts them. No property here
    /// exposes card values, and nothing sensitive is logged or persisted.
    @MainActor
    public final class CardElement {
        /// Per-component settings; `nil` means "follow the global checkout configuration".
        public struct Configuration {
            /// Show the saved-card list (`nil` = follow card-on-file being effective).
            public var showsSavedCards: Bool?
            /// Billing address form mode; can only switch a form off further, never force one on.
            public var billingAddress: AddressMode?
            /// Shipping address form mode; same rule as `billingAddress`.
            public var shippingAddress: AddressMode?
            /// Show the "save this card" option (`nil` = follow card-on-file being effective).
            public var showsSaveCardOption: Bool?

            public init() {}
        }

        /// How an address form is controlled by the component.
        public enum AddressMode: Sendable {
            /// Follow the session and the global switch.
            case automatic
            /// Hide the form.
            case off
        }

        /// The element's self-sizing view (zero height while unavailable).
        public var view: UIView { container }

        /// Whether the element has anything to show (`CARD` is offered by the session and not hidden by
        /// the global filter).
        public private(set) var isAvailable: Bool

        /// Whether the current selection is ready to pay: a selected saved card, or a valid card in the form.
        ///
        /// This covers the card (and the selection) only, not address-form validity: `confirm()` validates
        /// the shown address forms and returns `CARD_INPUT_INVALID` when they are incomplete. Changes are
        /// reported through `cardElementDidChangeCompleteness(_:)`.
        public var isComplete: Bool {
            guard isAvailable, !isEnded else { return false }
            if selection.selectedId != nil { return true }
            return newCardActive && (entry?.isComplete ?? false)
        }

        /// Receives height, selection and completeness changes. Held weakly.
        public weak var delegate: CardElementDelegate?

        // MARK: - Internal state

        private let container = CardElementContainerView()
        private let stack = UIStackView()
        private let appearance: ResolvedAppearance
        private let localize: (String) -> String
        private let ruleSet = CardRulesProvider.activeRuleSet()
        private let logoLoader = CardBrandLogoLoader()
        private let brandItems: [CardBrandItem]
        private var logos: [URL: UIImage] = [:]

        private var selection: SavedCardSelection
        private var rows: [SavedCardRow] = []
        private var newCardRow: CardElementNewCardRow?
        private(set) var entry: NewCardEntryView?
        private var newCardActive = false
        private var interactionEnabled = true
        private var isEnded = false
        private var lastHeight: CGFloat = 0
        private var lastComplete = false

        init(group: CheckoutElements, configuration: Configuration) {
            let context = group.coordinator.context
            let session = context.session
            let globalAppearance = group.appearance
            appearance = ResolvedAppearance.resolve(globalAppearance)
            localize = group.localize
            brandItems = CardBrandItem.items(from: context.visibleEntries)
            isAvailable = context.visibleEntries.contains { PaymentMethodModel.logicalKey($0) == "CARD" }
            let showsSavedCards = configuration.showsSavedCards ?? true
            selection = SavedCardSelection(
                cards: isAvailable && showsSavedCards ? context.savedCards : [])

            container.onMoveToWindow = { [weak group] screen in group?.screenMetrics?.recordMainScreen(screen) }
            container.heightProvider = { [weak self] in self?.measuredHeight() ?? 0 }
            container.onLayout = { [weak self] in self?.layoutDidChange() }

            guard isAvailable else {
                container.isHidden = true
                return
            }

            let billingMode = Self.effectiveMode(
                globalEnabled: globalAppearance.billingAddressEnabled, collect: session.collectBillingAddress,
                hasUsableEntry: context.billingEntryUsable, style: globalAppearance.billingAddressStyle,
                component: configuration.billingAddress)
            let shippingMode = Self.effectiveMode(
                globalEnabled: globalAppearance.shippingAddressEnabled, collect: session.collectShippingAddress,
                hasUsableEntry: context.shippingEntryUsable, style: globalAppearance.shippingAddressStyle,
                component: configuration.shippingAddress)
            let entry = NewCardEntryView(
                appearance: appearance, localize: localize, localeCode: group.localeCode, sessionId: session.id,
                cardBrandItems: brandItems, cardRuleSet: ruleSet, cardBinService: EmptyCardBinService(),
                cardRulesService: EmptyCardRulesService(), billingMode: billingMode, shippingMode: shippingMode,
                addressService: group.addressService,
                cardOnFileEnabled: context.cardOnFileEnabled && (configuration.showsSaveCardOption ?? true),
                saveCardByDefault: context.saveCardByDefault,
                scanPresenter: { [weak container = container] in container?.owningViewController })
            self.entry = entry
            entry.onEditingChanged = { [weak self] in self?.contentDidChange() }
            entry.onContentSizeChange = { [weak self] in self?.layoutDidChange() }
            entry.startBackgroundRefresh()

            buildLayout()
            if selection.isEmpty {
                newCardActive = true
            } else {
                selection.selectDefault()
            }
            refreshSelectionUI()
            preloadLogos(savedCards: selection.cards)
            lastHeight = measuredHeight()
            lastComplete = isComplete
            applyLock(group.coordinator.state)
        }

        // MARK: - Public

        /// Clears the typed card values, the save-card choice and every visible address field.
        public func clear() {
            entry?.clear()
            contentDidChange()
        }

        // MARK: - Composition

        /// Resolves one address form's effective mode: the host global switch and the backend decide, then
        /// the component may only switch the form off further.
        static func effectiveMode(
            globalEnabled: Bool, collect: Bool, hasUsableEntry: Bool, style: Appearance.AddressFormStyle,
            component: AddressMode?
        ) -> AddressCollectionMode {
            if component == .off { return .off }
            return .resolveAddressMode(
                .from(enabled: globalEnabled), collect: collect, hasUsableEntry: hasUsableEntry, style: style)
        }

        private func buildLayout() {
            stack.axis = .vertical
            stack.spacing = 12
            stack.translatesAutoresizingMaskIntoConstraints = false
            container.addSubview(stack)
            NSLayoutConstraint.activate([
                stack.topAnchor.constraint(equalTo: container.topAnchor),
                stack.leadingAnchor.constraint(equalTo: container.leadingAnchor),
                stack.trailingAnchor.constraint(equalTo: container.trailingAnchor),
                stack.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            ])

            for card in selection.cards {
                let isExpired = selection.isExpired(card)
                let row = SavedCardRow(
                    appearance: appearance, card: card,
                    expiredText: isExpired ? localize("sunbay.cof.expired") : nil, logoLoader: logoLoader)
                if !isExpired {
                    row.onTap = { [weak self] in self?.selectSaved(card.id) }
                }
                rows.append(row)
                stack.addArrangedSubview(row)
            }
            if !selection.isEmpty {
                let newRow = CardElementNewCardRow(
                    appearance: appearance, title: localize("sunbay.cof.newPaymentMethod"))
                newRow.onTap = { [weak self] in self?.selectNewCard() }
                newCardRow = newRow
                stack.addArrangedSubview(newRow)
            }
            if let entry { stack.addArrangedSubview(entry) }
        }

        // MARK: - Selection

        private func selectSaved(_ id: String) {
            guard interactionEnabled else { return }
            let changed = selection.selectedId != id || newCardActive
            guard selection.select(id) else { return }
            newCardActive = false
            refreshSelectionUI()
            if changed { selectionDidChange() }
        }

        private func selectNewCard() {
            guard interactionEnabled, !newCardActive else { return }
            selection.clearSelection()
            newCardActive = true
            refreshSelectionUI()
            selectionDidChange()
        }

        private func refreshSelectionUI() {
            for row in rows { row.setSelected(row.paymentMethodId == selection.selectedId) }
            newCardRow?.setSelected(newCardActive)
            entry?.isHidden = !newCardActive
        }

        private func selectionDidChange() {
            delegate?.cardElementDidChangeSelection(self)
            contentDidChange()
        }

        // MARK: - Sizing

        /// The content height for the current width (0 while unavailable).
        private func measuredHeight() -> CGFloat {
            guard isAvailable else { return 0 }
            let width = container.bounds.width > 0 ? container.bounds.width : 320
            return stack.systemLayoutSizeFitting(
                CGSize(width: width, height: UIView.layoutFittingCompressedSize.height),
                withHorizontalFittingPriority: .required,
                verticalFittingPriority: .fittingSizeLevel
            ).height
        }

        /// Content changed: refresh the intrinsic height and tell the delegate when it actually changed.
        private func contentDidChange() {
            reportHeight(measuredHeight())
            let complete = isComplete
            if complete != lastComplete {
                lastComplete = complete
                delegate?.cardElementDidChangeCompleteness(self)
            }
        }

        /// The container laid out (an address form finished loading, an error appeared, the width changed).
        private func layoutDidChange() {
            guard isAvailable else { return }
            reportHeight(measuredHeight())
        }

        private func reportHeight(_ height: CGFloat) {
            guard abs(height - lastHeight) > 0.5 else { return }
            lastHeight = height
            container.invalidateIntrinsicContentSize()
            delegate?.cardElementDidUpdateHeight(self)
        }

        // MARK: - Lock

        /// Mirrors the shared payment lock: disabled while confirming and once the payment settled
        /// (pending / unknown / succeeded / ended session); enabled again after a failure.
        func applyLock(_ state: ElementsCoordinator.State) {
            switch state {
            case .ready:
                isEnded = false
                setInputsEnabled(true)
            case .confirming:
                setInputsEnabled(false)
            case .finished:
                isEnded = true
                // Whatever the outcome, the element is over: no typed value stays in the disabled fields.
                entry?.clear()
                setInputsEnabled(false)
                contentDidChange()
            case .expired:
                isEnded = true
                entry?.clear()
                setInputsEnabled(false)
                contentDidChange()
            }
        }

        private func setInputsEnabled(_ enabled: Bool) {
            interactionEnabled = enabled
            entry?.setInteractionEnabled(enabled)
            for row in rows { row.isUserInteractionEnabled = enabled }
            newCardRow?.isUserInteractionEnabled = enabled
        }

        // MARK: - Payment

        /// What `confirm()` should do with the current selection.
        enum ConfirmPlan {
            /// Nothing to pay with.
            case nothingSelected
            /// The new-card form (or a shown address form) is invalid; inline errors are now visible.
            case invalidInput
            /// Submit this action.
            case action(CheckoutUserAction)
        }

        /// Reads the selection (and validates the new-card form, showing its inline errors).
        func prepareConfirm() -> ConfirmPlan {
            guard isAvailable else { return .nothingSelected }
            if let id = selection.selectedId { return .action(.confirmSavedCard(paymentMethodId: id)) }
            guard newCardActive, let entry else { return .nothingSelected }
            entry.clearCardError()
            guard let action = entry.makeConfirmAction() else {
                contentDidChange()
                return .invalidInput
            }
            return .action(action)
        }

        /// Display data for the current selection (`nil` when nothing payable is selected). Apple Pay never
        /// appears here. A typed card shows its brand only, never any digit.
        var paymentOption: PaymentOptionDisplayData? {
            guard isAvailable, !isEnded else { return nil }
            if let id = selection.selectedId, let card = selection.cards.first(where: { $0.id == id }) {
                let name = ruleSet.rules(forScheme: card.brand).displayName ?? card.brand.uppercased()
                let dots = "\u{00B7}\u{00B7}\u{00B7}\u{00B7}"
                return PaymentOptionDisplayData(
                    label: "\(name) \(dots)\(card.last4)", image: card.logoUrl.flatMap { logos[$0] },
                    paymentMethodType: "CARD")
            }
            guard newCardActive, let entry, entry.isComplete else { return nil }
            let name = entry.detectedBrandName
            let scheme = ruleSet.brands.first { $0.displayName == name }?.scheme
            let image = brandItems.first { $0.scheme == scheme }.flatMap { logos[$0.logoURL] }
            return PaymentOptionDisplayData(
                label: name ?? localize("sunbay.cof.newPaymentMethod"), image: image, paymentMethodType: "CARD")
        }

        private func preloadLogos(savedCards: [SavedCard]) {
            let urls = savedCards.compactMap(\.logoUrl) + brandItems.map(\.logoURL)
            for url in Set(urls) {
                logoLoader.image(for: url) { [weak self] image in
                    if let image { self?.logos[url] = image }
                }
            }
        }

        #if DEBUG
            // MARK: - Test seams

            var newCardEntryForTest: NewCardEntryView? { entry }
            var selectedSavedCardIdForTest: String? { selection.selectedId }
            var savedRowCountForTest: Int { rows.count }
            var isNewCardFormVisibleForTest: Bool { newCardActive && entry != nil }
            var isInteractiveForTest: Bool { interactionEnabled }
            func tapSavedCardForTest(_ id: String) { rows.first { $0.paymentMethodId == id }?.onTap?() }
            func tapNewCardRowForTest() { newCardRow?.onTap?() }
        #endif
    }

    /// The "New card" option row shown under the saved cards (same bordered look as `SavedCardRow`).
    final class CardElementNewCardRow: UIView {
        var onTap: (() -> Void)?
        private let appearance: ResolvedAppearance
        private var isSelectedRow = false

        init(appearance: ResolvedAppearance, title: String) {
            self.appearance = appearance
            super.init(frame: .zero)
            backgroundColor = appearance.componentBackground
            layer.cornerRadius = appearance.cornerRadius
            let label = UILabel()
            label.text = title
            label.font = appearance.cardFieldFont
            label.textColor = appearance.text
            label.translatesAutoresizingMaskIntoConstraints = false
            addSubview(label)
            NSLayoutConstraint.activate([
                label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
                label.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
                label.topAnchor.constraint(equalTo: topAnchor, constant: 12),
                label.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -12),
                heightAnchor.constraint(greaterThanOrEqualToConstant: 52),
            ])
            isAccessibilityElement = true
            accessibilityLabel = title
            accessibilityTraits = .button
            addGestureRecognizer(UITapGestureRecognizer(target: self, action: #selector(handleTap)))
            refreshBorder()
        }

        @available(*, unavailable)
        required init?(coder: NSCoder) {
            fatalError("init(coder:) is not supported")
        }

        func setSelected(_ selected: Bool) {
            isSelectedRow = selected
            accessibilityTraits = selected ? [.button, .selected] : .button
            refreshBorder()
        }

        override func traitCollectionDidChange(_ previousTraitCollection: UITraitCollection?) {
            super.traitCollectionDidChange(previousTraitCollection)
            refreshBorder()
        }

        private func refreshBorder() {
            let color = (isSelectedRow ? appearance.primary : appearance.border).resolvedColor(with: traitCollection)
            ThemeableView.applyDynamicLayerColors(
                to: layer, border: color,
                borderWidth: isSelectedRow ? max(appearance.borderWidth, 1) + 1 : max(appearance.borderWidth, 1),
                shadow: nil)
        }

        @objc private func handleTap() { onTap?() }
    }

    /// The element's host view: self-sizes from its content, collapses to zero height when unavailable,
    /// snapshots the screen metrics when it joins a window, and keeps the focused field visible inside the
    /// nearest ancestor scroll view.
    final class CardElementContainerView: UIView {
        var onMoveToWindow: ((UIScreen) -> Void)?
        var heightProvider: (() -> CGFloat)?
        var onLayout: (() -> Void)?

        override init(frame: CGRect) {
            super.init(frame: frame)
            let center = NotificationCenter.default
            center.addObserver(
                self, selector: #selector(fieldDidBeginEditing(_:)),
                name: UITextField.textDidBeginEditingNotification, object: nil)
            center.addObserver(
                self, selector: #selector(fieldDidBeginEditing(_:)),
                name: UITextView.textDidBeginEditingNotification, object: nil)
        }

        @available(*, unavailable)
        required init?(coder: NSCoder) {
            fatalError("init(coder:) is not supported")
        }

        override var intrinsicContentSize: CGSize {
            CGSize(width: UIView.noIntrinsicMetric, height: isHidden ? 0 : (heightProvider?() ?? 0))
        }

        #if DEBUG
            private(set) var invalidationCountForTest = 0
            override func invalidateIntrinsicContentSize() {
                invalidationCountForTest += 1
                super.invalidateIntrinsicContentSize()
            }
        #endif

        override func didMoveToWindow() {
            super.didMoveToWindow()
            if let screen = window?.screen { onMoveToWindow?(screen) }
        }

        override func layoutSubviews() {
            super.layoutSubviews()
            onLayout?()
        }

        /// The view controller that owns this view (presents the card scanner).
        var owningViewController: UIViewController? {
            var responder: UIResponder? = next
            while let current = responder {
                if let controller = current as? UIViewController { return controller }
                responder = current.next
            }
            return nil
        }

        @objc private func fieldDidBeginEditing(_ note: Notification) {
            guard let field = note.object as? UIView, field.isDescendant(of: self) else { return }
            DispatchQueue.main.async { [weak self, weak field] in
                guard let self, let field else { return }
                self.scrollIntoView(field)
            }
        }

        /// Scrolls `field` into view (16 pt margin) inside the nearest ancestor scroll view, if any.
        func scrollIntoView(_ field: UIView) {
            var ancestor = superview
            while let current = ancestor, !(current is UIScrollView) { ancestor = current.superview }
            guard let scrollView = ancestor as? UIScrollView else { return }
            let rect = scrollView.convert(field.bounds, from: field)
            scrollView.scrollRectToVisible(rect.insetBy(dx: 0, dy: -16), animated: true)
        }
    }
#endif
