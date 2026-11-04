#if canImport(UIKit)
    import UIKit

    /// The saved-card (COF) list (design §5, screen 2): a vertical stack of `SavedCardRow`s with radio
    /// selection.
    ///
    /// Selection is single-choice: setting `selectedPaymentMethodId` re-renders the radios and brand
    /// tints; tapping a row fires `onSelect(id)` (which does NOT submit — the content VC enables the
    /// Pay button). The "New card" entry row is NOT part of this list; it lives on the home page as a
    /// standalone row (so it shows even when there are no saved cards). The view holds only
    /// `SavedCard` display data (no sensitive payment data).
    ///
    /// iOS-only: gated by `#if canImport(UIKit)`; does not compile under the macOS host (`swift test`).
    final class SavedCardListView: UIView {
        /// Invoked with the selected payment method id when a saved-card row is tapped.
        var onSelect: ((String) -> Void)?

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
        ///   - cards: The saved cards to list.
        init(appearance: ResolvedAppearance, cards: [SavedCard]) {
            self.appearance = appearance
            super.init(frame: .zero)
            configureSubviews(cards: cards)
        }

        @available(*, unavailable)
        required init?(coder: NSCoder) {
            fatalError("init(coder:) is not supported")
        }

        private func configureSubviews(cards: [SavedCard]) {
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
