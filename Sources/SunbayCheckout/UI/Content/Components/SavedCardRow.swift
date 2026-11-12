#if canImport(UIKit)
    import UIKit

    /// A button whose touch area extends beyond its frame (the visible control stays compact).
    private final class ExpandedHitButton: UIButton {
        override func point(inside point: CGPoint, with event: UIEvent?) -> Bool {
            bounds.insetBy(dx: -8, dy: -8).contains(point)
        }
    }

    /// A single saved-card (COF) row (design §5, screen 2): the brand logo (a text badge when the card has no
    /// logo or it fails to load), the masked number `•••• <last4>`, and the `MM/YY` expiry. In manage mode
    /// the expiry gives way to a trailing delete button and taps no longer select the row.
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
        private let logoView = UIImageView()
        private let deleteButton = ExpandedHitButton(type: .system)
        private let logoLoader: CardBrandLogoLoader?
        private let deleteLabel: String
        private var isManaging = false
        /// Invoked when the trailing delete button (manage mode) is tapped.
        var onDelete: (() -> Void)?
        private let numberLabel = UILabel()
        private let expiryLabel = UILabel()
        private let contentStack = UIStackView()
        private var tapRecognizer: UITapGestureRecognizer?

        /// Invoked when the trailing "View more" affordance is tapped (set via
        /// `showViewMoreInsteadOfExpiry`). Distinct from `onTap` (the whole-row tap).
        private var onViewMore: (() -> Void)?

        /// The trailing "View more" control, when shown (for tests / visibility checks).
        private(set) var viewMoreControl: UIView?

        /// Creates a saved-card row.
        ///
        /// - Parameters:
        ///   - appearance: The resolved appearance providing colors, fonts, corner radius, border width.
        ///   - card: The saved card to display.
        ///   - expiredText: The localized "Expired" label when the card is expired; nil for a usable card.
        ///     An expired row is dimmed, shows this label instead of the expiry, and ignores taps.
        ///   - logoLoader: Loads `card.logoUrl`; nil keeps the text badge.
        ///   - deleteLabel: The accessibility label of the manage-mode delete button.
        init(
            appearance: ResolvedAppearance, card: SavedCard, expiredText: String? = nil,
            logoLoader: CardBrandLogoLoader? = nil, deleteLabel: String = ""
        ) {
            self.logoLoader = logoLoader
            self.deleteLabel = deleteLabel
            self.appearance = appearance
            self.paymentMethodId = card.id
            self.isExpired = expiredText != nil
            super.init(frame: .zero)
            configureSubviews(card: card, expiredText: expiredText)
        }

        /// Whether the card is expired (dimmed, not selectable).
        let isExpired: Bool

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

        private func configureSubviews(card: SavedCard, expiredText: String?) {
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

            expiryLabel.text = expiredText ?? String(format: "%02d/%02d", card.expMonth, card.expYear % 100)
            expiryLabel.font = UIFont.preferredFont(forTextStyle: .footnote)
            expiryLabel.textColor = expiredText == nil ? appearance.textSecondary : appearance.danger
            expiryLabel.setContentHuggingPriority(.required, for: .horizontal)
            expiryLabel.translatesAutoresizingMaskIntoConstraints = false

            logoView.contentMode = .scaleAspectFit
            logoView.isHidden = true
            logoView.translatesAutoresizingMaskIntoConstraints = false
            NSLayoutConstraint.activate([
                logoView.widthAnchor.constraint(equalToConstant: 30),
                logoView.heightAnchor.constraint(equalToConstant: 24),
            ])
            loadLogo(card.logoUrl)

            deleteButton.setImage(
                UIImage(systemName: "trash", withConfiguration: UIImage.SymbolConfiguration(pointSize: 15)),
                for: .normal)
            deleteButton.tintColor = appearance.danger
            deleteButton.accessibilityLabel = deleteLabel
            deleteButton.isHidden = true
            deleteButton.translatesAutoresizingMaskIntoConstraints = false
            deleteButton.addTarget(self, action: #selector(handleDelete), for: .touchUpInside)
            NSLayoutConstraint.activate([
                // Compact so the row keeps its normal height; the touch area is extended by `ExpandedHitButton`.
                deleteButton.widthAnchor.constraint(equalToConstant: 28),
                deleteButton.heightAnchor.constraint(equalToConstant: 28),
            ])

            contentStack.addArrangedSubview(logoView)
            contentStack.addArrangedSubview(brandBadge)
            contentStack.addArrangedSubview(numberLabel)
            contentStack.addArrangedSubview(expiryLabel)
            contentStack.addArrangedSubview(deleteButton)
            contentStack.axis = .horizontal
            contentStack.alignment = .center
            contentStack.spacing = 12
            contentStack.translatesAutoresizingMaskIntoConstraints = false
            addSubview(contentStack)

            NSLayoutConstraint.activate([
                contentStack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
                contentStack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
                contentStack.topAnchor.constraint(equalTo: topAnchor, constant: 12),
                contentStack.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -12),
                heightAnchor.constraint(greaterThanOrEqualToConstant: 52),
            ])

            isAccessibilityElement = true
            accessibilityLabel = "\(card.brand) \(card.last4)"
            if let expiredText {
                // Expired: dimmed, announced as not enabled, and no tap gesture at all.
                brandBadge.alpha = 0.5
                logoView.alpha = 0.5
                numberLabel.alpha = 0.5
                accessibilityTraits = [.button, .notEnabled]
                accessibilityValue = expiredText
            } else {
                accessibilityTraits = .button
                addGestureRecognizer(UITapGestureRecognizer(target: self, action: #selector(handleTap)))
                if let tap = gestureRecognizers?.last as? UITapGestureRecognizer { tapRecognizer = tap }
            }
            refreshBorder()
        }

        /// Loads the brand logo; on success it replaces the text badge, on any failure the badge stays.
        private func loadLogo(_ url: URL?) {
            guard let url, let logoLoader else { return }
            logoLoader.image(for: url) { [weak self] image in
                guard let self, let image else { return }
                self.logoView.image = image
                self.logoView.isHidden = false
                self.brandBadge.isHidden = true
            }
        }

        /// Enters or leaves manage mode: shows the delete button instead of the expiry / "View more",
        /// and makes the row non-selectable. The row exposes its children to VoiceOver while managing so
        /// the delete button is reachable.
        func setManaging(_ managing: Bool) {
            isManaging = managing
            // An expired row keeps its "Expired" label so the dimmed state stays explained.
            if viewMoreControl == nil { expiryLabel.isHidden = managing && !isExpired }
            viewMoreControl?.isHidden = managing
            deleteButton.isHidden = !managing
            isAccessibilityElement = !managing
            refreshBorder()
        }

        /// Shows or clears the in-flight delete state (the button is disabled and the row dimmed).
        func setDeleting(_ busy: Bool) {
            deleteButton.isEnabled = !busy
            alpha = busy ? 0.5 : 1
        }

        @objc private func handleDelete() {
            onDelete?()
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
            accessibilityTraits = isExpired ? [.staticText, .notEnabled] : .staticText
        }

        /// Replaces the trailing expiry with a tappable "View more ›" affordance, used by the collapsed
        /// home summary when there is more than one saved card so the drill-in lives on the card row
        /// itself (not a separate row). The card-brand + masked number stay; only the trailing slot
        /// changes. The affordance is its own accessibility button so VoiceOver announces the navigation
        /// separately from the static card summary.
        ///
        /// - Parameters:
        ///   - title: The localized "View more" copy.
        ///   - onTap: The navigation action (opens the full saved-card list).
        func showViewMoreInsteadOfExpiry(title: String, onTap: @escaping () -> Void) {
            onViewMore = onTap
            expiryLabel.isHidden = true

            let label = UILabel()
            label.text = title
            label.font = appearance.cardFieldFont
            label.textColor = appearance.primary
            label.setContentHuggingPriority(.required, for: .horizontal)

            let chevron = UIImageView(image: UIImage(systemName: "chevron.right"))
            chevron.tintColor = appearance.primary
            chevron.contentMode = .scaleAspectFit
            chevron.setContentHuggingPriority(.required, for: .horizontal)

            let viewMore = UIStackView(arrangedSubviews: [label, chevron])
            viewMore.axis = .horizontal
            viewMore.alignment = .center
            viewMore.spacing = 4
            viewMore.isUserInteractionEnabled = true
            viewMore.setContentHuggingPriority(.required, for: .horizontal)
            viewMore.isAccessibilityElement = true
            viewMore.accessibilityTraits = .button
            viewMore.accessibilityLabel = title
            viewMore.addGestureRecognizer(
                UITapGestureRecognizer(target: self, action: #selector(handleViewMoreTap)))

            contentStack.addArrangedSubview(viewMore)
            viewMoreControl = viewMore
        }

        @objc private func handleViewMoreTap() {
            onViewMore?()
        }

        override func traitCollectionDidChange(_ previousTraitCollection: UITraitCollection?) {
            super.traitCollectionDidChange(previousTraitCollection)
            refreshBorder()
        }

        private func refreshBorder() {
            // Manage mode shows no selection highlight (rows are not selectable then).
            let highlighted = isSelectedRow && !isManaging
            let borderColor = (highlighted ? appearance.primary : appearance.border)
                .resolvedColor(with: traitCollection)
            ThemeableView.applyDynamicLayerColors(
                to: layer,
                border: borderColor,
                borderWidth: highlighted ? max(appearance.borderWidth, 1) + 1 : max(appearance.borderWidth, 1),
                shadow: nil
            )
        }

        @objc private func handleTap() {
            guard !isManaging else { return }
            onTap?()
        }

        #if DEBUG
            /// Test readout: the trailing expiry text (`MM/YY`, or the expired label).
            var expiryTextForTest: String? { expiryLabel.text }
        #endif
    }
#endif
