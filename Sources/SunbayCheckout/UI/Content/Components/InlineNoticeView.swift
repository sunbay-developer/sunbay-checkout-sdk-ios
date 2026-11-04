#if canImport(UIKit)
    import UIKit

    /// A single inline notice block with two severities (design §5, screen 7 red alert block).
    ///
    /// `.error` renders a danger-tinted alert block (danger-tinted background + danger border + a
    /// warning icon + message), used for `.failed` payment states; `.info` renders the same layout in
    /// neutral (`textSecondary`) styling, used for `pending` / `unknown` notices. The view sits above
    /// the CTA and the sheet stays open and re-editable.
    ///
    /// On `show(_:severity: .error)` it fires an error haptic (`UINotificationFeedbackGenerator`) and
    /// posts a `.layoutChanged` accessibility notification so VoiceOver moves focus to the notice.
    ///
    /// The block's border is drawn on the view's own `CALayer`, so its `cgColor` is re-resolved on a
    /// light/dark change via the `ThemeableView` helper (design §4.3). `traitCollectionDidChangeForTest`
    /// exposes that same re-resolution path for unit tests that cannot drive a live trait environment.
    ///
    /// iOS-only: gated by `#if canImport(UIKit)`; does not compile under the macOS host (`swift test`).
    final class InlineNoticeView: UIView {
        /// The severity of the notice, which selects the color treatment.
        enum Severity {
            /// Danger-colored alert block (payment failed).
            case error
            /// Neutral notice (pending / unknown).
            case info
        }

        // MARK: - Private state

        private let appearance: ResolvedAppearance
        private var severity: Severity = .error

        private let iconView = UIImageView()
        private let messageLabel = UILabel()
        private let stack = UIStackView()

        // MARK: - Init

        /// Creates an inline notice with resolved appearance tokens.
        ///
        /// - Parameter appearance: The resolved appearance providing danger / secondary colors, corner
        ///   radius, border width, and the body font.
        init(appearance: ResolvedAppearance) {
            self.appearance = appearance
            super.init(frame: .zero)
            configureSubviews()
            isHidden = true
        }

        @available(*, unavailable)
        required init?(coder: NSCoder) {
            fatalError("init(coder:) is not supported")
        }

        // MARK: - Public API

        /// Shows the notice with a message and severity.
        ///
        /// For `.error`, fires an error haptic and posts a `.layoutChanged` accessibility notification.
        ///
        /// - Parameters:
        ///   - message: The message to display.
        ///   - severity: The severity (color treatment).
        func show(message: String, severity: Severity) {
            self.severity = severity
            messageLabel.text = message
            applySeverity()
            isHidden = false

            if severity == .error {
                UINotificationFeedbackGenerator().notificationOccurred(.error)
            }
            UIAccessibility.post(notification: .layoutChanged, argument: self)
        }

        /// Hides the notice.
        func hide() {
            isHidden = true
            messageLabel.text = nil
        }

        // MARK: - Severity application

        /// Applies the background tint, text color, icon, and border for the current severity, then
        /// re-resolves the CALayer border color against the current trait.
        private func applySeverity() {
            let tint: UIColor
            switch severity {
            case .error:
                tint = appearance.danger
                iconView.image = UIImage(systemName: "exclamationmark.triangle.fill")
            case .info:
                tint = appearance.textSecondary
                iconView.image = UIImage(systemName: "info.circle.fill")
            }

            iconView.tintColor = tint
            messageLabel.textColor = tint
            backgroundColor = tint.withAlphaComponent(0.1)

            refreshDynamicLayerColors()
        }

        // MARK: - Trait handling

        override func traitCollectionDidChange(_ previousTraitCollection: UITraitCollection?) {
            super.traitCollectionDidChange(previousTraitCollection)
            refreshDynamicLayerColors()
        }

        #if DEBUG
            /// Test readout: the notice's current message text.
            var messageForTest: String? { messageLabel.text }

            /// Test seam: runs the same color re-resolution path as `traitCollectionDidChange(_:)` without
            /// requiring a live trait environment.
            ///
            /// - Parameter trait: The trait collection to resolve against (callers typically pair this with
            ///   `overrideUserInterfaceStyle` so `UIColor.resolvedColor(with:)` returns the matching value).
            func traitCollectionDidChangeForTest(_ trait: UITraitCollection) {
                refreshDynamicLayerColors(trait: trait)
            }
        #endif

        /// Re-resolves and re-applies the border color (and width) from the dynamic border color against
        /// a trait collection, so the layer's `cgColor` snapshot tracks the active light/dark scheme.
        private func refreshDynamicLayerColors(trait: UITraitCollection? = nil) {
            let resolveTrait = trait ?? traitCollection
            let borderUIColor: UIColor
            switch severity {
            case .error:
                borderUIColor = appearance.danger.resolvedColor(with: resolveTrait)
            case .info:
                borderUIColor = appearance.textSecondary.resolvedColor(with: resolveTrait)
            }
            ThemeableView.applyDynamicLayerColors(
                to: layer,
                border: borderUIColor,
                borderWidth: max(appearance.borderWidth, 1),
                shadow: nil
            )
        }

        // MARK: - Layout

        /// Builds the icon + message stack and the rounded container.
        private func configureSubviews() {
            layer.cornerRadius = appearance.cornerRadius

            iconView.contentMode = .scaleAspectFit
            iconView.setContentHuggingPriority(.required, for: .horizontal)
            iconView.translatesAutoresizingMaskIntoConstraints = false

            messageLabel.font = appearance.cardFieldFont
            messageLabel.numberOfLines = 0
            messageLabel.translatesAutoresizingMaskIntoConstraints = false

            stack.axis = .horizontal
            stack.alignment = .center
            stack.spacing = 8
            stack.translatesAutoresizingMaskIntoConstraints = false
            stack.addArrangedSubview(iconView)
            stack.addArrangedSubview(messageLabel)
            addSubview(stack)

            NSLayoutConstraint.activate([
                stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
                stack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
                stack.topAnchor.constraint(equalTo: topAnchor, constant: 10),
                stack.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -10),
                iconView.widthAnchor.constraint(equalToConstant: 18),
                iconView.heightAnchor.constraint(equalToConstant: 18),
            ])
        }
    }
#endif
