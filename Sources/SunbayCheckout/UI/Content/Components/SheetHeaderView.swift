#if canImport(UIKit)
    import UIKit

    /// The sheet header bar (design §5, all screens top): a leading ‹ back button (hidden by default),
    /// a centered title with an always-present description line below it, and a trailing ✕ close button.
    ///
    /// The header is stateless beyond its title/description/back visibility; navigation decisions
    /// belong to the content VC (Task 8). Tapping back fires `onBack`; tapping close fires `onClose`.
    /// The back button is hidden until `setBackVisible(true)` so the root screen shows title + close
    /// only. The close button defaults to the secondary (gray) tint.
    ///
    /// The description label always reserves exactly one line of height (even when empty), so the
    /// header does not reflow as pages set or clear their subtitle copy.
    ///
    /// iOS-only: gated by `#if canImport(UIKit)`; does not compile under the macOS host (`swift test`).
    final class SheetHeaderView: UIView {
        /// Invoked when the back button is tapped.
        var onBack: (() -> Void)?
        /// Invoked when the close button is tapped.
        var onClose: (() -> Void)?

        private let appearance: ResolvedAppearance

        private let backButton = UIButton(type: .system)
        private let closeButton = UIButton(type: .system)
        private let titleLabel = UILabel()
        private let descriptionLabel = UILabel()
        private let titleStack = UIStackView()

        /// Creates the header with resolved appearance tokens and a localization closure.
        ///
        /// - Parameters:
        ///   - appearance: The resolved appearance providing text / primary colors and the title font.
        ///   - localize: The localization closure (used for the back / close accessibility labels).
        init(appearance: ResolvedAppearance, localize: @escaping (String) -> String) {
            self.appearance = appearance
            super.init(frame: .zero)
            configureSubviews(localize: localize)
        }

        @available(*, unavailable)
        required init?(coder: NSCoder) {
            fatalError("init(coder:) is not supported")
        }

        /// Sets the centered title.
        ///
        /// - Parameter title: The title text (already localized by the caller).
        func setTitle(_ title: String) {
            titleLabel.text = title
        }

        /// Sets the one-line description shown under the title.
        ///
        /// The label always reserves a single line of height; passing an empty string clears the copy
        /// without collapsing the row (so the header height stays stable across page switches). A
        /// zero-width space keeps the line laid out when the copy is empty.
        ///
        /// - Parameter description: The description text (already localized by the caller), or empty.
        func setDescription(_ description: String) {
            descriptionLabel.text = description.isEmpty ? "\u{200B}" : description
        }

        /// Enables or disables the back button (locked while a confirm is in flight).
        ///
        /// - Parameter enabled: Whether the back button is interactive.
        func setBackEnabled(_ enabled: Bool) {
            backButton.isEnabled = enabled
        }

        #if DEBUG
            /// Test readout: whether the back button is interactive.
            var isBackEnabledForTest: Bool { backButton.isEnabled }
        #endif

        /// Enables or disables the close (✕) button (locked while a confirm is in flight and during the
        /// success animation, so a tap cannot report `.canceled` for a payment that may succeed).
        ///
        /// - Parameter enabled: Whether the close button is interactive.
        func setCloseEnabled(_ enabled: Bool) {
            closeButton.isEnabled = enabled
            closeButton.alpha = enabled ? 1.0 : 0.4
            closeButton.accessibilityTraits = enabled ? .button : [.button, .notEnabled]
        }

        #if DEBUG
            /// Test readout: whether the close button is interactive.
            var isCloseEnabledForTest: Bool { closeButton.isEnabled }

            /// Test readout: whether the close button exposes the `.notEnabled` accessibility trait.
            var closeHasNotEnabledTraitForTest: Bool { closeButton.accessibilityTraits.contains(.notEnabled) }
        #endif

        /// Shows or hides the leading back button.
        ///
        /// - Parameter visible: Whether the back button is visible.
        func setBackVisible(_ visible: Bool) {
            backButton.isHidden = !visible
        }

        private func configureSubviews(localize: @escaping (String) -> String) {
            backButton.setImage(UIImage(systemName: "chevron.left"), for: .normal)
            backButton.tintColor = appearance.text
            backButton.isHidden = true
            backButton.accessibilityLabel = localize("sunbay.sheet.back")
            backButton.translatesAutoresizingMaskIntoConstraints = false
            backButton.addTarget(self, action: #selector(handleBack), for: .touchUpInside)

            closeButton.setImage(UIImage(systemName: "xmark"), for: .normal)
            closeButton.tintColor = appearance.textSecondary
            closeButton.accessibilityLabel = localize("sunbay.sheet.close")
            closeButton.translatesAutoresizingMaskIntoConstraints = false
            closeButton.addTarget(self, action: #selector(handleClose), for: .touchUpInside)

            titleLabel.font = appearance.titleFont
            titleLabel.textColor = appearance.text
            titleLabel.textAlignment = .center
            titleLabel.numberOfLines = 1

            descriptionLabel.font = appearance.sectionHeaderFont
            descriptionLabel.textColor = appearance.textSecondary
            descriptionLabel.textAlignment = .center
            descriptionLabel.numberOfLines = 1
            descriptionLabel.lineBreakMode = .byTruncatingTail
            // Reserve one line even when empty, so the header height is stable across page switches.
            descriptionLabel.text = "\u{200B}"

            titleStack.axis = .vertical
            titleStack.alignment = .center
            titleStack.spacing = 2
            titleStack.addArrangedSubview(titleLabel)
            titleStack.addArrangedSubview(descriptionLabel)
            titleStack.translatesAutoresizingMaskIntoConstraints = false

            addSubview(backButton)
            addSubview(titleStack)
            addSubview(closeButton)

            NSLayoutConstraint.activate([
                backButton.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
                backButton.centerYAnchor.constraint(equalTo: centerYAnchor),
                backButton.widthAnchor.constraint(equalToConstant: 44),
                backButton.heightAnchor.constraint(equalToConstant: 44),

                closeButton.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
                closeButton.centerYAnchor.constraint(equalTo: centerYAnchor),
                closeButton.widthAnchor.constraint(equalToConstant: 44),
                closeButton.heightAnchor.constraint(equalToConstant: 44),

                titleStack.centerXAnchor.constraint(equalTo: centerXAnchor),
                titleStack.centerYAnchor.constraint(equalTo: centerYAnchor),
                titleStack.leadingAnchor.constraint(greaterThanOrEqualTo: backButton.trailingAnchor, constant: 8),
                titleStack.trailingAnchor.constraint(lessThanOrEqualTo: closeButton.leadingAnchor, constant: -8),

                // Deterministic row height so the header/scroll split of the parent's vertical chain
                // stays unambiguous. Sized for the title + the always-present one-line description;
                // both labels are single-line and truncate instead of growing.
                heightAnchor.constraint(equalToConstant: 60),
            ])
        }

        @objc private func handleBack() {
            onBack?()
        }

        @objc private func handleClose() {
            onClose?()
        }
    }
#endif
