#if canImport(UIKit)
    import UIKit

    #if canImport(PassKit)
        import PassKit
    #endif

    /// The express-checkout (wallet) row (design §5, screen 1): an official Apple Pay button on top of
    /// an "Or pay using" divider that separates the wallet option from the card form below.
    ///
    /// The button is a real PassKit `PKPaymentButton` (per spec §7.4) pinned to fill the row so PassKit
    /// owns the glyph, label localization, and light/dark styling. This view only renders the button +
    /// divider and forwards taps via `onApplePayTapped`; **availability gating is the caller's job**
    /// (design §7.4 three-factor logic lives in the content VC / `ApplePayButton`).
    ///
    /// iOS-only: gated by `#if canImport(UIKit)`. The Apple Pay button additionally requires PassKit; on
    /// a platform without PassKit the view degrades to just the divider (the caller would not show it).
    final class ExpressCheckoutView: UIView {
        /// Where the "Or pay using" divider sits relative to the Apple Pay button.
        enum DividerPlacement {
            /// Button on top, divider below it (the row sits ABOVE the content that follows).
            case below
            /// Divider on top, button below it (the row sits BELOW the content that precedes it).
            case above
        }

        /// Invoked when the Apple Pay button is tapped.
        var onApplePayTapped: (() -> Void)?

        private let appearance: ResolvedAppearance

        private let dividerLabel = UILabel()
        private let leftRule = UIView()
        private let rightRule = UIView()
        private let dividerPlacement: DividerPlacement
        private let showsDivider: Bool

        /// Creates the express row with resolved appearance tokens.
        ///
        /// - Parameters:
        ///   - appearance: The resolved appearance providing the secondary text color, body font, and
        ///     corner radius for the Apple Pay button.
        ///   - dividerPlacement: Whether the divider sits below (default) or above the button.
        ///   - showsDivider: Whether to render the "Or pay using" divider at all. Pass `false` when the
        ///     express row is the only payment option on the page (nothing to separate it from).
        init(appearance: ResolvedAppearance, dividerPlacement: DividerPlacement = .below, showsDivider: Bool = true) {
            self.appearance = appearance
            self.dividerPlacement = dividerPlacement
            self.showsDivider = showsDivider
            super.init(frame: .zero)
            configureSubviews()
        }

        @available(*, unavailable)
        required init?(coder: NSCoder) {
            fatalError("init(coder:) is not supported")
        }

        private func configureSubviews() {
            let stack = UIStackView()
            stack.axis = .vertical
            stack.spacing = 12
            stack.translatesAutoresizingMaskIntoConstraints = false
            addSubview(stack)

            NSLayoutConstraint.activate([
                stack.topAnchor.constraint(equalTo: topAnchor),
                stack.leadingAnchor.constraint(equalTo: leadingAnchor),
                stack.trailingAnchor.constraint(equalTo: trailingAnchor),
                stack.bottomAnchor.constraint(equalTo: bottomAnchor),
            ])

            let payButton = makeApplePayButton()
            payButton.translatesAutoresizingMaskIntoConstraints = false
            payButton.heightAnchor.constraint(greaterThanOrEqualToConstant: 48).isActive = true
            guard showsDivider else {
                stack.addArrangedSubview(payButton)
                return
            }
            let divider = makeDivider()
            switch dividerPlacement {
            case .below:
                stack.addArrangedSubview(payButton)
                stack.addArrangedSubview(divider)
            case .above:
                stack.addArrangedSubview(divider)
                stack.addArrangedSubview(payButton)
            }
        }

        /// Builds the "Or pay using" divider: a centered caption flanked by two hairline rules.
        private func makeDivider() -> UIView {
            let container = UIView()

            dividerLabel.font = UIFont.preferredFont(forTextStyle: .footnote)
            dividerLabel.textColor = appearance.textSecondary
            dividerLabel.textAlignment = .center
            dividerLabel.translatesAutoresizingMaskIntoConstraints = false

            for rule in [leftRule, rightRule] {
                rule.backgroundColor = appearance.border
                rule.translatesAutoresizingMaskIntoConstraints = false
                rule.heightAnchor.constraint(equalToConstant: 1).isActive = true
                container.addSubview(rule)
            }
            container.addSubview(dividerLabel)

            NSLayoutConstraint.activate([
                dividerLabel.centerXAnchor.constraint(equalTo: container.centerXAnchor),
                dividerLabel.centerYAnchor.constraint(equalTo: container.centerYAnchor),
                dividerLabel.topAnchor.constraint(equalTo: container.topAnchor),
                dividerLabel.bottomAnchor.constraint(equalTo: container.bottomAnchor),

                leftRule.leadingAnchor.constraint(equalTo: container.leadingAnchor),
                leftRule.trailingAnchor.constraint(equalTo: dividerLabel.leadingAnchor, constant: -8),
                leftRule.centerYAnchor.constraint(equalTo: container.centerYAnchor),

                rightRule.leadingAnchor.constraint(equalTo: dividerLabel.trailingAnchor, constant: 8),
                rightRule.trailingAnchor.constraint(equalTo: container.trailingAnchor),
                rightRule.centerYAnchor.constraint(equalTo: container.centerYAnchor),
            ])
            return container
        }

        /// Sets the localized "Or pay using" divider caption.
        ///
        /// Kept as a setter (not an init arg) so the caller routes the single divider string through its
        /// `localize` closure after construction. See key `sunbay.sheet.orPayUsing`.
        ///
        /// - Parameter text: The localized divider caption.
        func setOrPayUsingText(_ text: String) {
            dividerLabel.text = text
        }

        /// Builds the Apple Pay button, using an official `PKPaymentButton` where PassKit is available.
        private func makeApplePayButton() -> UIView {
            #if canImport(PassKit)
                let button = PKPaymentButton(
                    paymentButtonType: appearance.applePayButtonType.pkType,
                    paymentButtonStyle: appearance.applePayButtonStyle.pkStyle)
                button.cornerRadius = appearance.primaryButtonCornerRadius
                button.addTarget(self, action: #selector(handleApplePayTap), for: .touchUpInside)
                return button
            #else
                // PassKit unavailable: render a neutral placeholder; the caller would not present this.
                let placeholder = UIView()
                placeholder.backgroundColor = appearance.componentBackground
                placeholder.layer.cornerRadius = appearance.primaryButtonCornerRadius
                return placeholder
            #endif
        }

        @objc private func handleApplePayTap() {
            onApplePayTapped?()
        }
    }
#endif
