#if canImport(UIKit)
    import UIKit

    /// A square checkbox control (design: the COF "Save card" toggle).
    ///
    /// Replaces `UISwitch` for the sheet's boolean opt-ins: an 18pt rounded square that renders an
    /// empty bordered box when off and a filled `primary` box with a white checkmark when on. Tapping
    /// toggles `isOn` and fires `.valueChanged`, so existing `addTarget(..., for: .valueChanged)` and
    /// `isOn` read sites keep working unchanged. Call `attachLabel(_:)` to let an adjacent caption
    /// toggle the box too.
    ///
    /// iOS-only: gated by `#if canImport(UIKit)`; does not compile under the macOS host (`swift test`).
    final class CheckboxControl: UIControl {
        private let appearance: ResolvedAppearance
        private let box = UIView()
        private let checkmark = UIImageView()

        private static let side: CGFloat = 18

        /// Whether the checkbox is selected. Setting it updates the visual state (no event fired).
        var isOn: Bool = false {
            didSet { refreshState() }
        }

        /// Creates the checkbox with resolved appearance tokens.
        ///
        /// - Parameter appearance: The resolved appearance providing the `primary` fill, border, and
        ///   corner radius.
        init(appearance: ResolvedAppearance) {
            self.appearance = appearance
            super.init(frame: .zero)
            configureSubviews()
        }

        @available(*, unavailable)
        required init?(coder: NSCoder) {
            fatalError("init(coder:) is not supported")
        }

        private func configureSubviews() {
            translatesAutoresizingMaskIntoConstraints = false
            isAccessibilityElement = true
            accessibilityTraits = .button

            box.isUserInteractionEnabled = false
            box.layer.cornerRadius = 4
            box.layer.borderWidth = 1.5
            box.translatesAutoresizingMaskIntoConstraints = false
            addSubview(box)

            let config = UIImage.SymbolConfiguration(pointSize: 11, weight: .bold)
            checkmark.image = UIImage(systemName: "checkmark", withConfiguration: config)
            checkmark.tintColor = appearance.primaryButtonText
            checkmark.contentMode = .scaleAspectFit
            checkmark.isHidden = true
            checkmark.translatesAutoresizingMaskIntoConstraints = false
            box.addSubview(checkmark)

            addTarget(self, action: #selector(handleTap), for: .touchUpInside)

            NSLayoutConstraint.activate([
                widthAnchor.constraint(equalToConstant: Self.side),
                heightAnchor.constraint(equalToConstant: Self.side),
                box.topAnchor.constraint(equalTo: topAnchor),
                box.leadingAnchor.constraint(equalTo: leadingAnchor),
                box.trailingAnchor.constraint(equalTo: trailingAnchor),
                box.bottomAnchor.constraint(equalTo: bottomAnchor),
                checkmark.centerXAnchor.constraint(equalTo: box.centerXAnchor),
                checkmark.centerYAnchor.constraint(equalTo: box.centerYAnchor),
            ])

            refreshState()
        }

        @objc private func handleTap() {
            toggle()
        }

        /// Toggles `isOn` and fires `.valueChanged` (shared by the box tap and an attached label tap).
        private func toggle() {
            guard isEnabled else { return }
            isOn.toggle()
            sendActions(for: .valueChanged)
        }

        /// Makes an adjacent caption label toggle this checkbox when tapped, so the whole
        /// "checkbox + text" row is a single tap target. The label becomes user-interactive.
        ///
        /// - Parameter label: The caption shown next to the checkbox.
        func attachLabel(_ label: UILabel) {
            label.isUserInteractionEnabled = true
            label.addGestureRecognizer(
                UITapGestureRecognizer(target: self, action: #selector(handleLabelTap)))
        }

        @objc private func handleLabelTap() {
            toggle()
        }

        override var isEnabled: Bool {
            didSet { alpha = isEnabled ? 1.0 : 0.4 }
        }

        override func traitCollectionDidChange(_ previousTraitCollection: UITraitCollection?) {
            super.traitCollectionDidChange(previousTraitCollection)
            refreshState()
        }

        /// Applies the on/off visual: filled `primary` + checkmark when on, empty bordered box when off.
        private func refreshState() {
            checkmark.isHidden = !isOn
            if isOn {
                box.backgroundColor = appearance.primary
                box.layer.borderColor = appearance.primary.resolvedColor(with: traitCollection).cgColor
            } else {
                box.backgroundColor = .clear
                box.layer.borderColor = appearance.border.resolvedColor(with: traitCollection).cgColor
            }
            accessibilityTraits = isOn ? [.button, .selected] : .button
        }
    }
#endif
