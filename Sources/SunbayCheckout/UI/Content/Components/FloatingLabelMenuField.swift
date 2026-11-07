#if canImport(UIKit)
    import UIKit

    /// A select / menu field whose label floats, mirroring `FloatingLabelTextField` for pop-up-menu
    /// controls (country / state pickers). The label rests over the value position (like a placeholder)
    /// when nothing is selected, and shrinks + rises to a top band once a value is chosen. A trailing
    /// chevron marks it as a menu, matching the native select affordance.
    ///
    /// ## Responsibility boundary
    /// Pure presentation. It owns a floating `UILabel`, a value `UILabel`, a trailing chevron, and a
    /// transparent `UIButton` that carries the caller's `UIMenu`. It holds no address data and logs
    /// nothing; the caller owns the menu actions and the selected model value.
    ///
    /// Float trigger: unlike a text field there is no first-responder / text, so the label floats iff a
    /// value is currently selected (`hasValue`). The caller drives this through `setSelected(title:)`
    /// (a non-nil, non-empty title means "selected") and `clearSelection(placeholderIsLabel:)`.
    ///
    /// iOS-only: gated by `#if canImport(UIKit)`; does not compile under the macOS host (`swift test`).
    final class FloatingLabelMenuField: UIControl {
        private let appearance: ResolvedAppearance
        private let floatingLabel = UILabel()
        private let valueLabel = UILabel()
        private let chevron = UIImageView(image: UIImage(systemName: "chevron.down"))
        private let menuButton = UIButton(type: .system)

        /// The top band reserved for the floated label, in points (shared token).
        private let floatBand = FloatingLabelMetrics.floatBand
        private let leadingInset: CGFloat = 0
        /// Room reserved on the trailing side for the chevron so the value/label never runs under it.
        private let trailingInset: CGFloat = 22

        /// The label text (shown as the resting placeholder and the floated label).
        let title: String

        /// Whether a value is currently selected (drives the float state).
        private var hasValue = false

        /// Creates the menu field.
        ///
        /// - Parameters:
        ///   - appearance: Resolved appearance tokens.
        ///   - title: The field label (localized).
        init(appearance: ResolvedAppearance, title: String) {
            self.appearance = appearance
            self.title = title
            super.init(frame: .zero)
            configure()
        }

        @available(*, unavailable)
        required init?(coder: NSCoder) {
            fatalError("init(coder:) is not supported")
        }

        // MARK: - Public API

        /// Attaches the pop-up menu (the caller owns its actions) and makes a tap present it.
        func setMenu(_ menu: UIMenu) {
            menuButton.menu = menu
            menuButton.showsMenuAsPrimaryAction = true
        }

        /// Marks the field as having a selected value and shows that value's display text; floats the
        /// label.
        ///
        /// - Parameter title: The selected value's display text.
        func setSelected(title: String) {
            valueLabel.text = title
            valueLabel.textColor = appearance.text
            hasValue = true
            setNeedsLayout()
        }

        /// Clears the selection: the field rests and the label drops back to the placeholder position.
        func clearSelection() {
            valueLabel.text = nil
            hasValue = false
            setNeedsLayout()
        }

        // MARK: - Setup

        private func configure() {
            floatingLabel.text = title
            floatingLabel.font = restingFont
            floatingLabel.textColor = appearance.textSecondary
            floatingLabel.translatesAutoresizingMaskIntoConstraints = true
            addSubview(floatingLabel)

            valueLabel.font = restingFont
            valueLabel.textColor = appearance.text
            valueLabel.translatesAutoresizingMaskIntoConstraints = true
            addSubview(valueLabel)

            chevron.tintColor = appearance.textSecondary
            chevron.contentMode = .scaleAspectFit
            chevron.translatesAutoresizingMaskIntoConstraints = false
            addSubview(chevron)

            menuButton.translatesAutoresizingMaskIntoConstraints = false
            addSubview(menuButton)

            NSLayoutConstraint.activate([
                chevron.trailingAnchor.constraint(equalTo: trailingAnchor),
                chevron.centerYAnchor.constraint(equalTo: centerYAnchor),
                chevron.widthAnchor.constraint(equalToConstant: 14),
                chevron.heightAnchor.constraint(equalToConstant: 14),

                // The transparent button fills the field so a tap anywhere presents the menu.
                menuButton.topAnchor.constraint(equalTo: topAnchor),
                menuButton.bottomAnchor.constraint(equalTo: bottomAnchor),
                menuButton.leadingAnchor.constraint(equalTo: leadingAnchor),
                menuButton.trailingAnchor.constraint(equalTo: trailingAnchor),
            ])
        }

        // MARK: - Float state

        private var restingFont: UIFont { FloatingLabelMetrics.fieldFont(from: appearance.cardFieldFont) }

        private var floatedFont: UIFont {
            FloatingLabelMetrics.floatedFont(from: restingFont)
        }

        override func layoutSubviews() {
            super.layoutSubviews()
            let width = max(0, bounds.width - leadingInset - trailingInset)

            if hasValue {
                floatingLabel.font = floatedFont
                floatingLabel.sizeToFit()
                floatingLabel.frame = CGRect(
                    x: leadingInset, y: FloatingLabelMetrics.floatedLabelTopInset, width: width,
                    height: floatingLabel.bounds.height)
                valueLabel.isHidden = false
                valueLabel.frame = CGRect(
                    x: leadingInset, y: floatBand, width: width,
                    height: max(0, bounds.height - floatBand - FloatingLabelMetrics.bottomInset))
            } else {
                // Resting: the label sits centered as a placeholder; no value shown.
                floatingLabel.font = restingFont
                floatingLabel.sizeToFit()
                floatingLabel.frame = CGRect(x: leadingInset, y: 0, width: width, height: bounds.height)
                valueLabel.isHidden = true
            }
        }

        #if DEBUG
            /// Test readout: whether the label is floated (a value is selected).
            var isLabelFloatedForTest: Bool { hasValue }

            /// Test readout: the currently shown value text (nil when resting).
            var valueTextForTest: String? { valueLabel.isHidden ? nil : valueLabel.text }
        #endif
    }
#endif
