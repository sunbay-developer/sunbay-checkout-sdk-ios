#if canImport(UIKit)
    import UIKit

    /// The saved-card (COF) list (design §5, screen 2): a vertical stack of `SavedCardRow`s with radio
    /// selection, followed by a "New card" row (card icon + title + chevron) that lets the user switch
    /// to manual entry.
    ///
    /// Selection is single-choice: setting `selectedPaymentMethodId` re-renders the radios and brand
    /// tints; tapping a row fires `onSelect(id)`; tapping the "New card" row fires `onTapNewCard`. The
    /// view holds only `SavedCard` display data (no sensitive payment data).
    ///
    /// iOS-only: gated by `#if canImport(UIKit)`; does not compile under the macOS host (`swift test`).
    final class SavedCardListView: UIView {
        /// Invoked with the selected payment method id when a saved-card row is tapped.
        var onSelect: ((String) -> Void)?
        /// Invoked when the "New card" row is tapped.
        var onTapNewCard: (() -> Void)?

        /// The currently selected payment method id (radio selection). Setting it updates the rows.
        var selectedPaymentMethodId: String? {
            didSet { applySelection() }
        }

        private let appearance: ResolvedAppearance
        private var rows: [SavedCardRow] = []

        /// Creates the saved-card list.
        ///
        /// - Parameters:
        ///   - appearance: The resolved appearance providing colors, fonts, corner radius, border width.
        ///   - localize: The localization closure for the "New card" row title.
        ///   - cards: The saved cards to list.
        init(appearance: ResolvedAppearance, localize: @escaping (String) -> String, cards: [SavedCard]) {
            self.appearance = appearance
            super.init(frame: .zero)
            configureSubviews(localize: localize, cards: cards)
        }

        @available(*, unavailable)
        required init?(coder: NSCoder) {
            fatalError("init(coder:) is not supported")
        }

        private func configureSubviews(localize: @escaping (String) -> String, cards: [SavedCard]) {
            let stack = UIStackView()
            stack.axis = .vertical
            stack.spacing = 8
            stack.translatesAutoresizingMaskIntoConstraints = false
            addSubview(stack)

            NSLayoutConstraint.activate([
                stack.topAnchor.constraint(equalTo: topAnchor),
                stack.leadingAnchor.constraint(equalTo: leadingAnchor),
                stack.trailingAnchor.constraint(equalTo: trailingAnchor),
                stack.bottomAnchor.constraint(equalTo: bottomAnchor),
            ])

            for card in cards {
                let row = SavedCardRow(appearance: appearance, card: card)
                row.onTap = { [weak self] in
                    self?.selectedPaymentMethodId = card.id
                    self?.onSelect?(card.id)
                }
                rows.append(row)
                stack.addArrangedSubview(row)
            }

            stack.addArrangedSubview(makeNewCardRow(localize: localize))
        }

        /// Builds the "New card" row: card icon + localized title + trailing chevron.
        private func makeNewCardRow(localize: @escaping (String) -> String) -> UIView {
            let container = UIView()
            container.backgroundColor = appearance.componentBackground
            container.layer.cornerRadius = appearance.cornerRadius
            container.layer.borderWidth = max(appearance.borderWidth, 1)
            container.layer.borderColor = appearance.border.cgColor

            let icon = UIImageView(image: UIImage(systemName: "creditcard"))
            icon.tintColor = appearance.primary
            icon.contentMode = .scaleAspectFit
            icon.setContentHuggingPriority(.required, for: .horizontal)
            icon.translatesAutoresizingMaskIntoConstraints = false

            let title = UILabel()
            title.text = localize("sunbay.cof.newPaymentMethod")
            title.font = appearance.cardFieldFont
            title.textColor = appearance.text
            title.translatesAutoresizingMaskIntoConstraints = false

            let chevron = UIImageView(image: UIImage(systemName: "chevron.right"))
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
                icon.heightAnchor.constraint(equalToConstant: 18),
                container.heightAnchor.constraint(greaterThanOrEqualToConstant: 52),
            ])

            container.isAccessibilityElement = true
            container.accessibilityTraits = .button
            container.accessibilityLabel = title.text
            container.addGestureRecognizer(
                UITapGestureRecognizer(target: self, action: #selector(handleNewCardTap)))
            return container
        }

        private func applySelection() {
            for row in rows {
                row.setSelected(row.paymentMethodId == selectedPaymentMethodId)
            }
        }

        @objc private func handleNewCardTap() {
            onTapNewCard?()
        }
    }
#endif
