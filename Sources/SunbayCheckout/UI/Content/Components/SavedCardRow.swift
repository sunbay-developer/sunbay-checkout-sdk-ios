#if canImport(UIKit)
    import UIKit

    /// A single saved-card (COF) row (design §5, screen 2): a brand badge, the masked number
    /// `•••• <last4>`, and the `MM/YY` expiry.
    ///
    /// The row is presentational: it renders a `SavedCard` and a selected flag, and forwards taps via
    /// `onTap`. Selection is shown by a theme-color border highlight only (no radio indicator): when
    /// selected, the border is tinted with the appearance primary (brand) color and thickened; otherwise
    /// it uses the neutral border. Carries no sensitive data — `SavedCard` holds only brand / last4 /
    /// expiry.
    ///
    /// iOS-only: gated by `#if canImport(UIKit)`; does not compile under the macOS host (`swift test`).
    final class SavedCardRow: UIView {
        /// The saved payment method id this row represents.
        let paymentMethodId: String

        /// Invoked when the row is tapped.
        var onTap: (() -> Void)?

        private let appearance: ResolvedAppearance
        private var isSelectedRow = false

        private let brandBadge = UILabel()
        private let numberLabel = UILabel()
        private let expiryLabel = UILabel()
        private var tapRecognizer: UITapGestureRecognizer?

        /// Creates a saved-card row.
        ///
        /// - Parameters:
        ///   - appearance: The resolved appearance providing colors, fonts, corner radius, border width.
        ///   - card: The saved card to display.
        init(appearance: ResolvedAppearance, card: SavedCard) {
            self.appearance = appearance
            self.paymentMethodId = card.id
            super.init(frame: .zero)
            configureSubviews(card: card)
        }

        @available(*, unavailable)
        required init?(coder: NSCoder) {
            fatalError("init(coder:) is not supported")
        }

        /// Sets the selected state (theme-color border highlight).
        ///
        /// - Parameter selected: Whether this row is the selected payment method.
        func setSelected(_ selected: Bool) {
            isSelectedRow = selected
            refreshBorder()
        }

        private func configureSubviews(card: SavedCard) {
            backgroundColor = appearance.componentBackground
            layer.cornerRadius = appearance.cornerRadius

            brandBadge.text = card.brand.uppercased()
            brandBadge.font = UIFont.preferredFont(forTextStyle: .caption1)
            brandBadge.textColor = appearance.text
            brandBadge.textAlignment = .center
            brandBadge.setContentHuggingPriority(.required, for: .horizontal)
            brandBadge.translatesAutoresizingMaskIntoConstraints = false

            numberLabel.text = "•••• \(card.last4)"
            numberLabel.font = appearance.cardFieldFont
            numberLabel.textColor = appearance.text
            numberLabel.translatesAutoresizingMaskIntoConstraints = false

            expiryLabel.text = String(format: "%02d/%02d", card.expMonth, card.expYear % 100)
            expiryLabel.font = UIFont.preferredFont(forTextStyle: .footnote)
            expiryLabel.textColor = appearance.textSecondary
            expiryLabel.setContentHuggingPriority(.required, for: .horizontal)
            expiryLabel.translatesAutoresizingMaskIntoConstraints = false

            let stack = UIStackView(arrangedSubviews: [brandBadge, numberLabel, expiryLabel])
            stack.axis = .horizontal
            stack.alignment = .center
            stack.spacing = 12
            stack.translatesAutoresizingMaskIntoConstraints = false
            addSubview(stack)

            NSLayoutConstraint.activate([
                stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
                stack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
                stack.topAnchor.constraint(equalTo: topAnchor, constant: 12),
                stack.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -12),
                heightAnchor.constraint(greaterThanOrEqualToConstant: 52),
            ])

            isAccessibilityElement = true
            accessibilityTraits = .button
            accessibilityLabel = "\(card.brand) \(card.last4)"

            addGestureRecognizer(UITapGestureRecognizer(target: self, action: #selector(handleTap)))
            if let tap = gestureRecognizers?.last as? UITapGestureRecognizer { tapRecognizer = tap }
            refreshBorder()
        }

        /// Presents the row as a static, non-interactive summary: removes the tap gesture and the
        /// `.button` accessibility trait so VoiceOver does not announce an action that never fires.
        /// Used for the collapsed home summary, where only the separate "View more" control navigates.
        func presentAsStaticSummary() {
            if let tap = tapRecognizer {
                removeGestureRecognizer(tap)
                tapRecognizer = nil
            }
            onTap = nil
            accessibilityTraits = .staticText
        }

        override func traitCollectionDidChange(_ previousTraitCollection: UITraitCollection?) {
            super.traitCollectionDidChange(previousTraitCollection)
            refreshBorder()
        }

        private func refreshBorder() {
            let borderColor = (isSelectedRow ? appearance.primary : appearance.border)
                .resolvedColor(with: traitCollection)
            ThemeableView.applyDynamicLayerColors(
                to: layer,
                border: borderColor,
                borderWidth: isSelectedRow ? max(appearance.borderWidth, 1) + 1 : max(appearance.borderWidth, 1),
                shadow: nil
            )
        }

        @objc private func handleTap() {
            onTap?()
        }
    }
#endif
