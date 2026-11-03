#if canImport(UIKit)
    import UIKit

    /// The sheet footer trust badge (design §5, every screen bottom): a lock glyph plus a localized
    /// "Powered by SUNBAY" caption rendered in `textSecondary`.
    ///
    /// Purely decorative / informational — it has no interaction and holds no state. All visible copy
    /// is routed through the injected `localize` closure (key `sunbay.sheet.poweredBy`).
    ///
    /// iOS-only: gated by `#if canImport(UIKit)`; does not compile under the macOS host (`swift test`).
    final class CheckoutFooterView: UIView {
        private let appearance: ResolvedAppearance

        private let iconView = UIImageView()
        private let label = UILabel()
        private let stack = UIStackView()

        /// Creates the footer with resolved appearance tokens and a localization closure.
        ///
        /// - Parameters:
        ///   - appearance: The resolved appearance providing the secondary text color and body font.
        ///   - localize: The localization closure for the "Powered by SUNBAY" caption.
        init(appearance: ResolvedAppearance, localize: @escaping (String) -> String) {
            self.appearance = appearance
            super.init(frame: .zero)
            configureSubviews(localize: localize)
        }

        @available(*, unavailable)
        required init?(coder: NSCoder) {
            fatalError("init(coder:) is not supported")
        }

        private func configureSubviews(localize: @escaping (String) -> String) {
            iconView.image = UIImage(systemName: "lock.fill")
            iconView.tintColor = appearance.textSecondary
            iconView.contentMode = .scaleAspectFit
            iconView.setContentHuggingPriority(.required, for: .horizontal)
            iconView.translatesAutoresizingMaskIntoConstraints = false

            label.text = localize("sunbay.sheet.poweredBy")
            label.font = UIFont.preferredFont(forTextStyle: .caption1)
            label.textColor = appearance.textSecondary
            label.translatesAutoresizingMaskIntoConstraints = false

            stack.axis = .horizontal
            stack.alignment = .center
            stack.spacing = 4
            stack.translatesAutoresizingMaskIntoConstraints = false
            stack.addArrangedSubview(iconView)
            stack.addArrangedSubview(label)
            addSubview(stack)

            NSLayoutConstraint.activate([
                stack.centerXAnchor.constraint(equalTo: centerXAnchor),
                stack.topAnchor.constraint(equalTo: topAnchor, constant: 8),
                stack.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -8),
                stack.leadingAnchor.constraint(greaterThanOrEqualTo: leadingAnchor),
                stack.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor),
                iconView.widthAnchor.constraint(equalToConstant: 12),
                iconView.heightAnchor.constraint(equalToConstant: 12),
            ])
        }
    }
#endif
