#if canImport(UIKit)
    import UIKit

    /// The saved-card (COF) list (design §5, screen 2): a vertical stack of `SavedCardRow`s with
    /// single-choice selection.
    ///
    /// Selection is single-choice: setting `selectedPaymentMethodId` re-renders the rows' border
    /// highlight; tapping a row fires `onSelect(id)` (which does NOT submit — the content VC enables the
    /// Pay button). The "New card" entry row is NOT part of this list; it lives on the home page as a
    /// standalone row (so it shows even when there are no saved cards). The view holds only
    /// `SavedCard` display data (no sensitive payment data).
    ///
    /// iOS-only: gated by `#if canImport(UIKit)`; does not compile under the macOS host (`swift test`).
    final class SavedCardListView: UIView {
        /// Invoked with the selected payment method id when a saved-card row is tapped.
        var onSelect: ((String) -> Void)?

        /// The currently selected payment method id (single-choice). Setting it updates the rows.
        var selectedPaymentMethodId: String? {
            didSet { applySelection() }
        }

        private let appearance: ResolvedAppearance
        private var rows: [SavedCardRow] = []
        private let stack = UIStackView()
        private let logoLoader: CardBrandLogoLoader?
        private let deleteLabel: String

        /// Invoked with the card id when a row's delete button (manage mode) is tapped.
        var onDelete: ((String) -> Void)?

        /// Creates the saved-card list.
        ///
        /// - Parameters:
        ///   - appearance: The resolved appearance providing colors, fonts, corner radius, border width.
        ///   - cards: The saved cards to list.
        ///   - expiredText: Returns the localized "Expired" label for an expired card, or nil when the
        ///     card is usable. Expired rows are dimmed and cannot be selected.
        init(
            appearance: ResolvedAppearance, cards: [SavedCard], logoLoader: CardBrandLogoLoader? = nil,
            deleteLabel: String = "", expiredText: (SavedCard) -> String? = { _ in nil }
        ) {
            self.logoLoader = logoLoader
            self.deleteLabel = deleteLabel
            self.appearance = appearance
            super.init(frame: .zero)
            configureSubviews(cards: cards, expiredText: expiredText)
        }

        @available(*, unavailable)
        required init?(coder: NSCoder) {
            fatalError("init(coder:) is not supported")
        }

        private func configureSubviews(cards: [SavedCard], expiredText: (SavedCard) -> String?) {
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
                let row = SavedCardRow(
                    appearance: appearance, card: card, expiredText: expiredText(card),
                    logoLoader: logoLoader, deleteLabel: deleteLabel)
                row.onDelete = { [weak self] in self?.onDelete?(card.id) }
                if !row.isExpired {
                    row.onTap = { [weak self] in
                        self?.selectedPaymentMethodId = card.id
                        self?.onSelect?(card.id)
                    }
                }
                rows.append(row)
                stack.addArrangedSubview(row)
            }
        }

        /// Enters or leaves manage mode for every row.
        func setManaging(_ managing: Bool) {
            rows.forEach { $0.setManaging(managing) }
        }

        /// Shows or clears the in-flight delete state of one row.
        func setDeleting(_ id: String, _ busy: Bool) {
            rows.first { $0.paymentMethodId == id }?.setDeleting(busy)
        }

        /// Removes one card's row.
        func removeCard(_ id: String) {
            guard let index = rows.firstIndex(where: { $0.paymentMethodId == id }) else { return }
            let row = rows.remove(at: index)
            stack.removeArrangedSubview(row)
            row.removeFromSuperview()
        }

        #if DEBUG
            /// Test seam: fires the exact closure a real row tap runs (selection + `onSelect`).
            func tapRowForTest(_ paymentMethodId: String) {
                rows.first { $0.paymentMethodId == paymentMethodId }?.onTap?()
            }
        #endif

        private func applySelection() {
            for row in rows {
                row.setSelected(row.paymentMethodId == selectedPaymentMethodId)
            }
        }
    }
#endif
