#if canImport(UIKit)
    import UIKit

    /// The internal rendering layer of `PaymentSheet` (product-spec §2.2).
    ///
    /// ## Responsibility boundary
    /// A minimal but real modal `UIViewController` that renders the available payment methods
    /// from the loaded session and the (after the COF decision) listed saved cards, and reports
    /// the user's selection back to `PaymentSheet` via `onAction`:
    /// - **Saved-card list** (when `savedCards` is non-empty): one row each, tap →
    ///   `.confirmSavedCard(paymentMethodId:)`.
    /// - **New-card form** (`CardField`, Task 10) + a "save this card" toggle: tap "Pay" →
    ///   `.confirmNewCard(cardInput, save: toggle.isOn)` (the toggle drives save + consent).
    /// - **Apple Pay option** (when the session `.methods` contains `.applePay`): here it only
    ///   renders the entry point; the real wallet authorization is handled by L3
    ///   `ApplePayButton`, and this page's Apple Pay row reports `.cancel` as a placeholder (the
    ///   example app / Task 13 wires up the real authorization).
    /// - **Cancel**: the navigation-bar cancel button → `.cancel`.
    ///
    /// This VC **holds no business rules, does not encrypt, and does not log/persist** any card
    /// data: the plaintext carried by `CardField.cardInput` is only forwarded as-is to
    /// `PaymentSheet` (and then encrypted by `CardEncryptor` inside
    /// `CheckoutController.confirmNewCard`), and discarded after use (§5 / AGENTS.md §2).
    ///
    /// internal: not exposed externally; the full UI is verified by the example app (Task 13). iOS-only (`#if canImport(UIKit)`).
    final class PaymentSheetViewController: UIViewController {
        /// Called when the user completes one selection (on the main thread). Carries a `PaymentSheet.UserAction`. Called exactly once.
        var onAction: ((PaymentSheet.UserAction) -> Void)?

        // MARK: - Rendering inputs

        private let session: CheckoutSession
        private let savedCards: [SavedCard]
        /// Localized-string provider injected by `PaymentSheet` (built from a `LocalizationResolver`).
        /// Maps a `sunbay.sheet.*` key to the title string in the resolved locale.
        private let localize: (String) -> String

        // MARK: - Subviews

        private let scrollView = UIScrollView()
        private let contentStack = UIStackView()
        private let cardField = CardField()
        private let saveCardSwitch = UISwitch()

        /// The visible button/label titles collected while building the layout. Test-only readout (see `renderedTitles`).
        private var collectedTitles: [String] = []

        /// Reentrancy guard: onAction fires only once (the terminal state dismisses this page from PaymentSheet).
        private var didReportAction = false

        /// Creates the payment page VC.
        ///
        /// - Parameters:
        ///   - session: The loaded session, validated as not expired (used to render merchant/amount/available methods).
        ///   - savedCards: The listed saved cards (empty when COF is unavailable).
        ///   - localize: Localized-string provider mapping a `sunbay.sheet.*` key to its title in the resolved locale.
        init(session: CheckoutSession, savedCards: [SavedCard], localize: @escaping (String) -> String) {
            self.session = session
            self.savedCards = savedCards
            self.localize = localize
            super.init(nibName: nil, bundle: nil)
        }

        @available(*, unavailable)
        required init?(coder: NSCoder) {
            fatalError("init(coder:) is not supported")
        }

        override func viewDidLoad() {
            super.viewDidLoad()
            // Semantic theme color: follows the light/dark scheme, does not hardcode a fixed color (same principle as AGENTS.md §5.4).
            view.backgroundColor = .systemBackground
            buildLayout()
        }

        // MARK: - Test readout

        /// The visible button/label titles produced during layout, in build order.
        ///
        /// internal, test-only: lets localization tests assert that titles were resolved
        /// through the injected `localize` closure. Call after `loadViewIfNeeded()`.
        func renderedTitles() -> [String] {
            collectedTitles
        }

        // MARK: - Layout

        private func buildLayout() {
            // Cancel entry point (top).
            let cancelButton = UIButton(type: .system)
            let cancelTitle = localize("sunbay.sheet.cancel")
            cancelButton.setTitle(cancelTitle, for: .normal)
            collectedTitles.append(cancelTitle)
            cancelButton.addTarget(self, action: #selector(handleCancel), for: .touchUpInside)

            // Merchant / amount header.
            let title = UILabel()
            title.text = session.merchantName
            title.font = .preferredFont(forTextStyle: .headline)
            title.textColor = .label

            scrollView.translatesAutoresizingMaskIntoConstraints = false
            contentStack.axis = .vertical
            contentStack.spacing = 16
            contentStack.translatesAutoresizingMaskIntoConstraints = false

            view.addSubview(scrollView)
            scrollView.addSubview(contentStack)
            NSLayoutConstraint.activate([
                scrollView.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
                scrollView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
                scrollView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
                scrollView.bottomAnchor.constraint(equalTo: view.bottomAnchor),

                contentStack.topAnchor.constraint(equalTo: scrollView.contentLayoutGuide.topAnchor, constant: 16),
                contentStack.leadingAnchor.constraint(equalTo: scrollView.frameLayoutGuide.leadingAnchor, constant: 16),
                contentStack.trailingAnchor.constraint(equalTo: scrollView.frameLayoutGuide.trailingAnchor, constant: -16),
                contentStack.bottomAnchor.constraint(equalTo: scrollView.contentLayoutGuide.bottomAnchor, constant: -16),
            ])

            contentStack.addArrangedSubview(cancelButton)
            contentStack.addArrangedSubview(title)

            // Saved-card list (COF; only when there are cards).
            if !savedCards.isEmpty {
                let header = sectionLabel(localize("sunbay.sheet.savedCards"))
                contentStack.addArrangedSubview(header)
                for card in savedCards {
                    contentStack.addArrangedSubview(savedCardRow(card))
                }
                contentStack.addArrangedSubview(separator())
            }

            // New-card form.
            contentStack.addArrangedSubview(sectionLabel(localize("sunbay.sheet.newCard")))
            cardField.translatesAutoresizingMaskIntoConstraints = false
            contentStack.addArrangedSubview(cardField)

            // "Save this card" toggle (drives save + consent).
            let saveRow = UIStackView()
            saveRow.axis = .horizontal
            saveRow.spacing = 8
            let saveLabel = UILabel()
            let saveTitle = localize("sunbay.sheet.saveThisCard")
            saveLabel.text = saveTitle
            collectedTitles.append(saveTitle)
            saveLabel.textColor = .label
            saveRow.addArrangedSubview(saveLabel)
            saveRow.addArrangedSubview(saveCardSwitch)
            contentStack.addArrangedSubview(saveRow)

            // The new-card "Pay" button.
            let payButton = UIButton(type: .system)
            let payTitle = localize("sunbay.sheet.pay")
            payButton.setTitle(payTitle, for: .normal)
            collectedTitles.append(payTitle)
            payButton.addTarget(self, action: #selector(handlePayNewCard), for: .touchUpInside)
            contentStack.addArrangedSubview(payButton)

            // Apple Pay option (when the backend allows). Real authorization is handled by L3 ApplePayButton (see the type description).
            if session.methods.contains(.applePay) {
                contentStack.addArrangedSubview(separator())
                let applePayButton = UIButton(type: .system)
                let applePayTitle = localize("sunbay.sheet.applePay")
                applePayButton.setTitle(applePayTitle, for: .normal)
                collectedTitles.append(applePayTitle)
                applePayButton.addTarget(self, action: #selector(handleApplePay), for: .touchUpInside)
                contentStack.addArrangedSubview(applePayButton)
            }
        }

        private func sectionLabel(_ text: String) -> UILabel {
            let label = UILabel()
            label.text = text
            label.font = .preferredFont(forTextStyle: .subheadline)
            label.textColor = .secondaryLabel
            collectedTitles.append(text)
            return label
        }

        private func separator() -> UIView {
            let line = UIView()
            line.backgroundColor = .separator
            line.heightAnchor.constraint(equalToConstant: 1).isActive = true
            return line
        }

        /// Constructs one saved-card row (tap → confirmSavedCard). Uses the tag to carry the index to locate the card.
        private func savedCardRow(_ card: SavedCard) -> UIButton {
            let button = UIButton(type: .system)
            button.contentHorizontalAlignment = .leading
            button.setTitle("\(card.brand) •••• \(card.last4)", for: .normal)
            if let index = savedCards.firstIndex(where: { $0.id == card.id }) {
                button.tag = index
            }
            button.addTarget(self, action: #selector(handleSavedCardTap(_:)), for: .touchUpInside)
            return button
        }

        // MARK: - Actions

        @objc private func handleCancel() {
            report(.cancel)
        }

        @objc private func handleSavedCardTap(_ sender: UIButton) {
            guard savedCards.indices.contains(sender.tag) else { return }
            report(.confirmSavedCard(paymentMethodId: savedCards[sender.tag].id))
        }

        @objc private func handlePayNewCard() {
            // Fields incomplete → do not start (minimal validation is handled by CardField); keep the page editable.
            guard let input = cardField.cardInput else { return }
            report(.confirmNewCard(input, save: saveCardSwitch.isOn))
        }

        @objc private func handleApplePay() {
            // This page only renders the entry point; real PassKit authorization is handled by L3 ApplePayButton. Reports cancel as a placeholder,
            // and the example app (Task 13) changes it to .confirmWallet(token:) after wiring up the real authorization.
            report(.cancel)
        }

        /// Reports one user action (fires only once).
        private func report(_ action: PaymentSheet.UserAction) {
            guard !didReportAction else { return }
            didReportAction = true
            onAction?(action)
        }
    }
#endif
