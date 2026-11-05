#if canImport(UIKit)
    import UIKit

    /// A single bordered, rounded field box wrapping one control (text field or menu button) — the
    /// address forms' per-field container.
    ///
    /// The border tracks focus: when the wrapped control (or any descendant text field) begins editing
    /// the border switches to the theme `primary` color, and reverts to the neutral `border` color on
    /// end. Menu-button fields never begin editing, so they simply keep the neutral border. The border
    /// is a `CALayer.cgColor`, so it is re-resolved on focus changes and on light/dark trait changes.
    ///
    /// iOS-only: gated by `#if canImport(UIKit)`; does not compile under the macOS host (`swift test`).
    final class FieldContainerView: UIView {
        private let appearance: ResolvedAppearance
        // Named `isEditing` (not `isFocused`) to avoid colliding with UIView's own `isFocused`.
        private var isEditing = false

        /// Wraps a control in a bordered field box.
        ///
        /// - Parameters:
        ///   - appearance: The resolved appearance providing the component background, corner radius,
        ///     border width / color, and the `primary` focus color.
        ///   - control: The control to embed. A `UITextField` wires its focus to the border; other
        ///     controls (e.g. menu buttons) keep the neutral border.
        init(appearance: ResolvedAppearance, control: UIView) {
            self.appearance = appearance
            super.init(frame: .zero)
            configure(control: control)
        }

        @available(*, unavailable)
        required init?(coder: NSCoder) {
            fatalError("init(coder:) is not supported")
        }

        private func configure(control: UIView) {
            backgroundColor = appearance.componentBackground
            layer.cornerRadius = appearance.cornerRadius

            control.translatesAutoresizingMaskIntoConstraints = false
            addSubview(control)
            NSLayoutConstraint.activate([
                control.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
                control.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
                control.topAnchor.constraint(equalTo: topAnchor, constant: 6),
                control.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -6),
                heightAnchor.constraint(greaterThanOrEqualToConstant: 48),
            ])

            if let field = control as? UITextField {
                field.addTarget(self, action: #selector(handleEditingDidBegin), for: .editingDidBegin)
                field.addTarget(self, action: #selector(handleEditingDidEnd), for: .editingDidEnd)
            }

            refreshBorder()
        }

        @objc private func handleEditingDidBegin() {
            isEditing = true
            refreshBorder()
        }

        @objc private func handleEditingDidEnd() {
            isEditing = false
            refreshBorder()
        }

        override func traitCollectionDidChange(_ previousTraitCollection: UITraitCollection?) {
            super.traitCollectionDidChange(previousTraitCollection)
            refreshBorder()
        }

        /// Applies the border: `primary` when focused, otherwise the neutral `border`, re-resolving the
        /// `cgColor` against the current trait.
        private func refreshBorder() {
            let color = (isEditing ? appearance.primary : appearance.border)
                .resolvedColor(with: traitCollection)
            layer.borderWidth = max(appearance.borderWidth, 1)
            layer.borderColor = color.cgColor
        }
    }
#endif
