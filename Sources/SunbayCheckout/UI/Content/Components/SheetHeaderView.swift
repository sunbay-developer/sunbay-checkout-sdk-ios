#if canImport(UIKit)
    import UIKit

    /// The sheet header bar (design §5, all screens top): a leading ‹ back button (hidden by default),
    /// a centered title, and a trailing ✕ close button.
    ///
    /// The header is stateless beyond its title / back visibility; navigation decisions belong to the
    /// content VC (Task 8). Tapping back fires `onBack`; tapping close fires `onClose`. The back button
    /// is hidden until `setBackVisible(true)` so the root screen shows title + close only. The close
    /// button defaults to the secondary (gray) tint. The title, back, and close all sit on one row,
    /// vertically centered and aligned with each other.
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

        /// Shows or hides the trailing close (✕) button.
        ///
        /// Visibility is orthogonal to the enabled state controlled by `setCloseEnabled(_:)`: the
        /// content VC hides close on sub-pages (where back is shown instead) and shows it on the home
        /// page, while `setCloseEnabled(_:)` independently dims it while a confirm is in flight.
        ///
        /// - Parameter visible: Whether the close button is visible.
        func setCloseVisible(_ visible: Bool) {
            closeButton.isHidden = !visible
        }

        #if DEBUG
            /// Test readout: whether the close button is visible.
            var isCloseVisibleForTest: Bool { !closeButton.isHidden }
        #endif

        private func configureSubviews(localize: @escaping (String) -> String) {
            let buttonConfig = UIImage.SymbolConfiguration(pointSize: 14, weight: .semibold)
            backButton.setImage(
                UIImage(systemName: "chevron.left", withConfiguration: buttonConfig), for: .normal)
            backButton.tintColor = appearance.text
            backButton.isHidden = true
            backButton.accessibilityLabel = localize("sunbay.sheet.back")
            backButton.translatesAutoresizingMaskIntoConstraints = false
            backButton.addTarget(self, action: #selector(handleBack), for: .touchUpInside)

            closeButton.setImage(
                UIImage(systemName: "xmark", withConfiguration: buttonConfig), for: .normal)
            closeButton.tintColor = appearance.textSecondary
            closeButton.accessibilityLabel = localize("sunbay.sheet.close")
            closeButton.translatesAutoresizingMaskIntoConstraints = false
            closeButton.addTarget(self, action: #selector(handleClose), for: .touchUpInside)

            titleLabel.font = appearance.titleFont
            titleLabel.textColor = appearance.text
            titleLabel.textAlignment = .center
            titleLabel.numberOfLines = 1
            titleLabel.translatesAutoresizingMaskIntoConstraints = false

            addSubview(backButton)
            addSubview(titleLabel)
            addSubview(closeButton)

            NSLayoutConstraint.activate([
                // Back / close / title share one row: all vertically centered and aligned with each other.
                backButton.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
                backButton.centerYAnchor.constraint(equalTo: centerYAnchor),
                backButton.widthAnchor.constraint(equalToConstant: 36),
                backButton.heightAnchor.constraint(equalToConstant: 36),

                closeButton.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
                closeButton.centerYAnchor.constraint(equalTo: centerYAnchor),
                closeButton.widthAnchor.constraint(equalToConstant: 36),
                closeButton.heightAnchor.constraint(equalToConstant: 36),

                titleLabel.centerXAnchor.constraint(equalTo: centerXAnchor),
                titleLabel.centerYAnchor.constraint(equalTo: centerYAnchor),
                titleLabel.leadingAnchor.constraint(greaterThanOrEqualTo: backButton.trailingAnchor, constant: 8),
                titleLabel.trailingAnchor.constraint(lessThanOrEqualTo: closeButton.leadingAnchor, constant: -8),

                // Deterministic row height so the parent's header → scroll → bottom-bar vertical chain
                // stays unambiguous. The title is single-line and truncates instead of growing.
                heightAnchor.constraint(equalToConstant: 44),
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
