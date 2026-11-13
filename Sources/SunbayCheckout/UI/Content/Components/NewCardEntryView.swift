#if canImport(UIKit)
    import UIKit

    /// The new-card entry column, extracted from `CheckoutContentViewController` so it can be hosted
    /// by the bottom sheet today and by an inline card element later: the "Card information" header
    /// (with the optional scan button), the card form, the optional "Save this card" row, and the
    /// billing / shipping address forms.
    ///
    /// It owns the card-brand scheme resolution (BIN lookup) and the validation / assembly of the
    /// confirm action. Plaintext card data lives only inside `CardFormView`'s fields; this view stores
    /// none of it and exposes only a brand name (never digits). Nothing here is logged.
    final class NewCardEntryView: UIView {
        // MARK: - Public surface

        /// Invoked whenever the card form's content changes (so the owner can re-evaluate its CTA).
        var onEditingChanged: (() -> Void)?

        /// Whether the card number / expiry / CVC currently form a valid `CardInput`.
        var isComplete: Bool { cardForm.cardInput != nil }

        /// The detected card brand's display name (for example "Visa"), or `nil`. Brand only; never digits.
        var detectedBrandName: String? { cardForm.detectedBrandName }

        /// Whether the SDK shows a billing / shipping address form.
        var billingFormShown: Bool { billingAddressView != nil }
        var shippingFormShown: Bool { shippingAddressView != nil }

        // MARK: - Dependencies

        private let appearance: ResolvedAppearance
        private let localize: (String) -> String
        private let localeCode: String?
        private let addressService: any AddressMetadataService
        private let cardRulesService: any CardRulesService
        private let cardOnFileEnabled: Bool
        private let saveCardByDefault: Bool
        private let scanPresenter: () -> UIViewController?

        // MARK: - Components

        private let cardForm: CardFormView
        /// Resolves the scheme from the BIN.
        private let schemeResolver: CardSchemeResolver
        /// The "Save this card" (COF consent) checkbox, present only when card-on-file is enabled.
        private var saveCardSwitch: CheckboxControl?
        private(set) var billingAddressView: UIView?
        private(set) var shippingAddressView: UIView?
        private var shippingContainer: UIStackView?
        private let stack = UIStackView()

        // MARK: - Init

        init(
            appearance: ResolvedAppearance,
            localize: @escaping (String) -> String,
            localeCode: String?,
            sessionId: String,
            cardBrandItems: [CardBrandItem],
            cardRuleSet: CardRuleSet,
            cardBinService: any CardBinService,
            cardRulesService: any CardRulesService,
            billingMode: AddressCollectionMode,
            shippingMode: AddressCollectionMode,
            addressService: any AddressMetadataService,
            cardOnFileEnabled: Bool,
            saveCardByDefault: Bool,
            scanPresenter: @escaping () -> UIViewController?,
            cardRulesStore: CardRulesStore = CardRulesStore(),
            cardRulesGate: CardRulesRefreshGate = .shared
        ) {
            self.appearance = appearance
            self.localize = localize
            self.localeCode = localeCode
            self.addressService = addressService
            self.cardRulesService = cardRulesService
            self.cardOnFileEnabled = cardOnFileEnabled
            self.saveCardByDefault = saveCardByDefault
            self.scanPresenter = scanPresenter
            let form = CardFormView(
                appearance: appearance, localize: localize, ruleSet: cardRuleSet, brandItems: cardBrandItems)
            self.cardForm = form
            self.schemeResolver = CardSchemeResolver(
                service: cardBinService, sessionId: sessionId,
                onChange: { [weak form] scheme in form?.setBackendScheme(scheme) })
            super.init(frame: .zero)

            cardForm.onPANDigitsChanged = { [weak self] digits in self?.schemeResolver.digitsChanged(digits) }
            cardForm.onEditingChanged = { [weak self] in self?.onEditingChanged?() }
            buildLayout(billingMode: billingMode, shippingMode: shippingMode)

            // Keep the cached rules fresh. The rules in effect for this form are already fixed; an update
            // applies the next time a card form is built. The empty default never fetches, so it must not
            // use up the shared gate.
            if !(cardRulesService is EmptyCardRulesService) {
                CardRulesRefresher.refreshInBackground(
                    service: cardRulesService, store: cardRulesStore, gate: cardRulesGate)
            }
        }

        @available(*, unavailable)
        required init?(coder: NSCoder) {
            fatalError("init(coder:) is not supported")
        }

        // MARK: - Actions

        /// Called when the content height may have changed outside user editing (an address form finished
        /// loading, an inline address error appeared or cleared).
        var onContentSizeChange: (() -> Void)?

        /// Refreshes the card-brand rules in the background; they apply the next time a card form is shown.
        func startBackgroundRefresh() {
            CardRulesRefresher.refreshInBackground(service: cardRulesService)
        }

        /// Validates the card and every shown address form and, when all are valid, assembles the confirm
        /// action. Returns `nil` (after showing the field errors / focusing the first offending address
        /// field) when anything is invalid. The returned action carries plaintext: never log or persist it.
        func makeConfirmAction() -> CheckoutUserAction? {
            guard let input = cardForm.cardInput else {
                if !cardForm.showValidationIssue() {
                    cardForm.showFieldError(.number, message: localize("sunbay.card.invalid"))
                }
                return nil
            }
            // Validate every shown address form (no short-circuit, so each shows its own error).
            let addressViews = [billingAddressView, shippingAddressView].compactMap { $0 as? DynamicAddressFormView }
            let addressResults = addressViews.map { $0.validate() }
            guard addressResults.allSatisfy({ $0 }) else {
                // Bring the first offending address field up (billing before shipping).
                _ = addressViews.first(where: { $0.focusFirstError() })
                return nil
            }
            let save = saveCardSwitch?.isOn ?? false
            let billing = formAddress(from: billingAddressView)
            // The shipping form's own values; nil when there is no shipping section.
            let shipping = formAddress(from: shippingAddressView)
            return .confirmNewCard(
                input, save: save, billing: billing, shipping: shipping,
                billingFormShown: billingAddressView != nil,
                shippingFormShown: shippingAddressView != nil)
        }

        /// Clears the card-number field error (used when a new confirm starts).
        func clearCardError() {
            cardForm.showFieldError(.number, message: nil)
        }

        /// Enables or disables every input (card form, save checkbox, billing view, shipping section).
        func setInteractionEnabled(_ enabled: Bool) {
            // Disabling interaction does not by itself resign an active first responder.
            if !enabled { endEditing(true) }
            cardForm.isUserInteractionEnabled = enabled
            saveCardSwitch?.isEnabled = enabled
            billingAddressView?.isUserInteractionEnabled = enabled
            shippingContainer?.isUserInteractionEnabled = enabled
        }

        /// Clears every field and error.
        func clear() {
            cardForm.clear()
            (billingAddressView as? DynamicAddressFormView)?.clearValues()
            (shippingAddressView as? DynamicAddressFormView)?.clearValues()
            saveCardSwitch?.isOn = saveCardByDefault
        }

        /// The values currently entered in an address form (nil when the form is absent). PII: never logged.
        private func formAddress(from view: UIView?) -> AddressInput? {
            switch view {
            case let dynamic as DynamicAddressFormView: return dynamic.addressInput
            default: return nil
            }
        }

        // MARK: - Layout

        private func buildLayout(billingMode: AddressCollectionMode, shippingMode: AddressCollectionMode) {
            stack.axis = .vertical
            stack.spacing = 16
            stack.translatesAutoresizingMaskIntoConstraints = false
            addSubview(stack)
            NSLayoutConstraint.activate([
                stack.topAnchor.constraint(equalTo: topAnchor),
                stack.leadingAnchor.constraint(equalTo: leadingAnchor),
                stack.trailingAnchor.constraint(equalTo: trailingAnchor),
                stack.bottomAnchor.constraint(equalTo: bottomAnchor),
            ])

            stack.addArrangedSubview(makeCardInformationHeader())
            stack.addArrangedSubview(cardForm)

            if cardOnFileEnabled {
                let saveRow = makeSaveCardRow()
                stack.addArrangedSubview(saveRow)
                // Pull "Save this card" up close to the card form, and push the Address area below it
                // further down, so the opt-in reads as belonging to the card (not the address).
                stack.setCustomSpacing(8, after: cardForm)
                stack.setCustomSpacing(28, after: saveRow)
            }

            if let billing = makeAddressView(mode: billingMode, options: .billing) {
                billingAddressView = billing
                stack.addArrangedSubview(makeSectionTitle("sunbay.address.billingTitle"))
                stack.addArrangedSubview(billing)
            }

            if let shippingSection = makeShippingSection(mode: shippingMode) {
                stack.addArrangedSubview(shippingSection)
            }
        }

        private func makeSaveCardRow() -> UIView {
            let checkbox = CheckboxControl(appearance: appearance)
            checkbox.isOn = saveCardByDefault
            saveCardSwitch = checkbox
            // Toggling is a deliberate step away from the fields: hide the keyboard (the background tap
            // recognizer ignores controls, so the checkbox box would otherwise leave it up).
            checkbox.addAction(
                UIAction { [weak self] _ in self?.endEditing(true) }, for: .valueChanged)

            let label = UILabel()
            label.text = localize("sunbay.sheet.saveThisCard")
            label.font = appearance.optionLabelFont
            label.textColor = appearance.optionLabelColor
            label.translatesAutoresizingMaskIntoConstraints = false
            checkbox.attachLabel(label)

            // One-line, merchant-neutral explanation of what saving does (Stripe-style).
            let hint = UILabel()
            hint.text = localize("sunbay.sheet.saveThisCardHint")
            hint.font = appearance.optionHintFont
            hint.textColor = appearance.textSecondary
            hint.numberOfLines = 0
            hint.translatesAutoresizingMaskIntoConstraints = false
            checkbox.attachLabel(hint)

            let texts = UIStackView(arrangedSubviews: [label, hint])
            texts.axis = .vertical
            texts.spacing = 2

            // Left-aligned: checkbox leads the text, with a trailing spacer so the row hugs the
            // leading edge. Top-aligned so the checkbox sits beside the title line, not the hint.
            let spacer = UIView()
            spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
            let row = UIStackView(arrangedSubviews: [checkbox, texts, spacer])
            row.axis = .horizontal
            row.alignment = .top
            row.spacing = 8
            return row
        }

        /// Builds the "Card information" header row: the section title on the left and, when scanning is
        /// available (auto-detected, unless the host disabled it), a themed "Scan card" button on the right.
        private func makeCardInformationHeader() -> UIView {
            let title = makeSectionTitle("sunbay.card.informationTitle")
            #if !targetEnvironment(macCatalyst)
                guard CardScanAvailability.isAvailable(policy: appearance.cardScanning) else { return title }

                let button = UIButton(type: .system)
                let config = UIImage.SymbolConfiguration(pointSize: 12, weight: .semibold)
                button.setImage(UIImage(systemName: "camera.fill", withConfiguration: config), for: .normal)
                button.setTitle(" " + localize("sunbay.card.scan"), for: .normal)
                button.titleLabel?.font = appearance.optionHintFont
                button.tintColor = appearance.primary
                button.setTitleColor(appearance.primary, for: .normal)
                button.accessibilityLabel = localize("sunbay.card.scan")
                button.setContentHuggingPriority(.required, for: .horizontal)
                button.setContentCompressionResistancePriority(.required, for: .horizontal)
                button.addTarget(self, action: #selector(scanCardTapped), for: .touchUpInside)

                title.setContentHuggingPriority(.defaultLow, for: .horizontal)
                let row = UIStackView(arrangedSubviews: [title, button])
                row.axis = .horizontal
                row.alignment = .center
                row.spacing = 8
                return row
            #else
                return title
            #endif
        }

        #if !targetEnvironment(macCatalyst)
            @objc private func scanCardTapped() {
                // Without a presenter at tap time there is nothing to present from: do nothing.
                guard let presenter = scanPresenter() else { return }
                endEditing(true)
                let scanner = CardScanViewController(appearance: appearance, localize: localize)
                scanner.onScanned = { [weak self] card in
                    // `applyScannedCard` reports the change through the form's `onEditingChanged`.
                    self?.cardForm.applyScannedCard(card)
                }
                presenter.present(scanner, animated: true)
            }
        #endif

        /// Builds a group section header: uppercased, semibold, in the primary text color and the
        /// small `sectionHeaderFont`. Shared by the "Card information", billing, and shipping titles.
        private func makeSectionTitle(_ key: String) -> UILabel {
            let label = UILabel()
            label.text = localize(key).uppercased()
            label.font = appearance.sectionHeaderFont
            label.textColor = appearance.text
            return label
        }

        /// Builds a billing/shipping address view for a collection mode, or nil if there is none.
        private func makeAddressView(mode: AddressCollectionMode, options: AddressFormOptions) -> UIView? {
            switch mode {
            case .simple:
                // Simple mode is the dynamic form restricted to country, line1, postal code and names,
                // wrapped so an unavailable metadata service degrades to a minimal local config.
                let labels = FallbackAddressMetadataService.Labels(
                    firstName: localize("sunbay.address.firstName"),
                    lastName: localize("sunbay.address.lastName"),
                    line1: localize("sunbay.address.line1"),
                    postalCode: localize("sunbay.address.postalCode"))
                let form = DynamicAddressFormView(
                    appearance: appearance, localize: localize,
                    service: FallbackAddressMetadataService(wrapping: addressService, labels: labels),
                    locale: localeCode, options: options,
                    visibleFields: [.country, .line1, .postalCode, .firstName, .lastName])
                form.onContentSizeChange = { [weak self] in self?.onContentSizeChange?() }
                return form
            case .full:
                let form = DynamicAddressFormView(
                    appearance: appearance, localize: localize, service: addressService,
                    locale: localeCode, options: options)
                form.onContentSizeChange = { [weak self] in self?.onContentSizeChange?() }
                return form
            case .off, .automatic:
                // `.automatic` is resolved by the owner before it reaches here.
                return nil
            }
        }

        /// Builds the shipping section: a title and the shipping form. There is no "same as billing"
        /// shortcut because the shipping form also collects name and phone, which billing does not.
        private func makeShippingSection(mode: AddressCollectionMode) -> UIView? {
            guard let shipping = makeAddressView(mode: mode, options: .shipping) else { return nil }
            shippingAddressView = shipping
            let container = UIStackView(arrangedSubviews: [makeSectionTitle("sunbay.address.shippingTitle"), shipping])
            container.axis = .vertical
            container.spacing = 12
            shippingContainer = container
            return container
        }

        #if DEBUG
            // MARK: - Test seams

            /// Fills the card form with a valid test card (bypasses keystrokes). By default it first lets any
            /// address form finish loading, since a confirm is ignored while address metadata loads.
            func fillCardForTest(awaitingAddressLoad: Bool = true) {
                if awaitingAddressLoad {
                    (billingAddressView as? DynamicAddressFormView)?.waitForLoadForTest()
                    (shippingAddressView as? DynamicAddressFormView)?.waitForLoadForTest()
                }
                cardForm.setFieldsForTest(pan: "4242424242424242", expiry: "12/99", cvv: "123")
                onEditingChanged?()
            }

            /// Types into the number field through the real delegate path.
            func typePANForTest(_ text: String) { cardForm.typePANForTest(text) }

            var panTextForTest: String { cardForm.panTextForTest }
            func focusPANForTest() { cardForm.focusPANForTest() }
            var isPANFirstResponderForTest: Bool { cardForm.isPANFirstResponderForTest }

            var isSaveCardRowVisible: Bool { saveCardSwitch != nil }
            var isSaveCardOn: Bool { saveCardSwitch?.isOn ?? false }
            func setSaveCard(_ on: Bool) { saveCardSwitch?.isOn = on }
            var isCardFormInteractive: Bool { cardForm.isUserInteractionEnabled }
            var hasCardFieldError: Bool { cardForm.hasFieldErrorForTest }
        #endif
    }
#endif
