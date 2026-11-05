#if canImport(UIKit)
    import UIKit

    /// A text field whose label floats: it rests over the text baseline (like a placeholder) when the
    /// field is empty and unfocused, and shrinks + rises to a top band when the field is focused OR has
    /// content — so a filled field always shows what it is (design §Part 2).
    ///
    /// ## Responsibility boundary
    /// This is pure presentation. It owns only its floating `UILabel`, the float/un-float animation, and
    /// the text insets that keep the text clear of the floated label. It never logs, persists, encrypts,
    /// or validates — card plaintext only ever lives in the field's `text`, exactly as with a bare
    /// `UITextField` (security-and-pci.md §4).
    ///
    /// The label text is set via `title` (not `placeholder`, which stays empty so there is no double
    /// text). Focus/content changes are observed through the field's own editing control events, so no
    /// external wiring is required for the float behavior; a `delegate` and extra targets set by the
    /// owner (formatting, CTA refresh) continue to work alongside the internal ones.
    ///
    /// iOS-only: gated by `#if canImport(UIKit)`; does not compile under the macOS host (`swift test`).
    final class FloatingLabelTextField: UITextField {
        private let appearance: ResolvedAppearance
        private let floatingLabel = UILabel()

        /// Whether the owner has marked this field as being in error (forces the danger label color,
        /// taking precedence over the focus/primary color).
        private var isErrorActive = false

        /// The top band reserved for the floated label, in points.
        private let floatBand: CGFloat = 18

        /// Leading inset for the floated label, matching the text's leading edge.
        private let horizontalInset: CGFloat = 0

        /// Trailing room reserved for the floated label so a long label is not clipped by a trailing
        /// accessory (e.g. the card-number brand icon that sits just past the field's trailing edge).
        private let labelTrailingInset: CGFloat = 8

        /// The floating label's text. Replaces `placeholder` usage; `placeholder` stays empty.
        var title: String? {
            didSet {
                floatingLabel.text = title
                setNeedsLayout()
            }
        }

        /// Creates the field with resolved appearance tokens.
        ///
        /// - Parameter appearance: The resolved appearance providing colors and the field font.
        init(appearance: ResolvedAppearance) {
            self.appearance = appearance
            super.init(frame: .zero)
            configure()
        }

        @available(*, unavailable)
        required init?(coder: NSCoder) {
            fatalError("init(coder:) is not supported")
        }

        // MARK: - Public API

        /// Marks (or clears) the field's error state, driving the floated label color. The owner calls
        /// this alongside its existing error styling (e.g. the group border); this type owns only the
        /// label color.
        ///
        /// - Parameter active: Whether the field is in error.
        func setErrorActive(_ active: Bool) {
            isErrorActive = active
            updateLabelColor()
        }

        // MARK: - Setup

        private func configure() {
            font = appearance.cardFieldFont
            textColor = appearance.text

            floatingLabel.text = title
            floatingLabel.font = appearance.cardFieldFont
            floatingLabel.textColor = appearance.textSecondary
            // The label is frame-positioned in `layoutFloatingLabel` (it moves between resting and
            // floated), so it keeps autoresizing-mask translation and takes no constraints.
            floatingLabel.translatesAutoresizingMaskIntoConstraints = true
            addSubview(floatingLabel)

            addTarget(self, action: #selector(handleEditingDidBegin), for: .editingDidBegin)
            addTarget(self, action: #selector(handleEditingDidEnd), for: .editingDidEnd)
            addTarget(self, action: #selector(handleEditingChanged), for: .editingChanged)

            updateLabelColor()
        }

        // MARK: - Float state

        /// Whether the label should float: focused, or there is text.
        private var shouldFloat: Bool {
            isFirstResponder || !(text ?? "").isEmpty
        }

        /// The resting (un-floated) font: the field font.
        private var restingFont: UIFont { appearance.cardFieldFont }

        /// The floated (small) font, derived from the field font so Dynamic Type still applies.
        private var floatedFont: UIFont {
            restingFont.withSize(max(11, restingFont.pointSize * 0.72))
        }

        private func updateLabelColor() {
            let color: UIColor
            if isErrorActive {
                color = appearance.danger
            } else if isFirstResponder {
                color = appearance.primary
            } else {
                color = appearance.textSecondary
            }
            floatingLabel.textColor = color
        }

        /// Applies the current float state to the label (position + font + color), animating unless
        /// page transitions are disabled or Reduce Motion is on.
        private func applyFloatState(animated: Bool) {
            let animate = animated && appearance.pageTransitionsEnabled && !UIAccessibility.isReduceMotionEnabled
            let work: () -> Void = { [weak self] in
                // `layoutFloatingLabel` updates position, font, and color together.
                self?.layoutFloatingLabel()
            }
            if animate {
                UIView.animate(withDuration: 0.15, delay: 0, options: [.curveEaseInOut], animations: work)
            } else {
                work()
            }
        }

        /// Positions the floating label for the current state. Resting: full font, vertically centered
        /// with the (resting) text. Floated: small font, pinned to the top band.
        private func layoutFloatingLabel() {
            let floating = shouldFloat
            floatingLabel.font = floating ? floatedFont : restingFont
            floatingLabel.sizeToFit()
            // Position and color share this one trigger so they can never diverge (e.g. after a
            // programmatic `text =` set, which fires no editing event but does trigger layout).
            updateLabelColor()

            let width = max(0, bounds.width - horizontalInset - labelTrailingInset)
            if floating {
                floatingLabel.frame = CGRect(
                    x: horizontalInset, y: 0, width: width, height: floatBand)
            } else {
                // Rest exactly where the field's own text is drawn (same rect as `textRect`), so the
                // resting label sits on the text baseline and reads as a true placeholder — vertically
                // centered in the text area rather than pinned low.
                let textArea = textRect(forBounds: bounds)
                floatingLabel.frame = CGRect(
                    x: horizontalInset, y: textArea.minY, width: width, height: textArea.height)
            }
        }

        // MARK: - Layout

        override func layoutSubviews() {
            super.layoutSubviews()
            layoutFloatingLabel()
        }

        /// The content rect for the text.
        ///
        /// When floated, the top `floatBand` is reserved so the text never overlaps the raised label.
        /// When resting (empty + unfocused), the full height is used so the label/placeholder sits
        /// vertically centered in the field rather than pinned to the lower band.
        private func insetRect(_ bounds: CGRect) -> CGRect {
            let topReserve = shouldFloat ? floatBand : 0
            return CGRect(
                x: bounds.minX + horizontalInset,
                y: bounds.minY + topReserve,
                width: bounds.width - horizontalInset * 2,
                height: bounds.height - topReserve)
        }

        override func textRect(forBounds bounds: CGRect) -> CGRect {
            insetRect(bounds)
        }

        override func editingRect(forBounds bounds: CGRect) -> CGRect {
            insetRect(bounds)
        }

        override func placeholderRect(forBounds bounds: CGRect) -> CGRect {
            insetRect(bounds)
        }

        // MARK: - Editing events

        @objc private func handleEditingDidBegin() {
            applyFloatState(animated: true)
        }

        @objc private func handleEditingDidEnd() {
            applyFloatState(animated: true)
        }

        @objc private func handleEditingChanged() {
            applyFloatState(animated: true)
        }

        #if DEBUG
            /// Test readout: whether the label is currently in its floated (small, top-band) state.
            var isLabelFloatedForTest: Bool { shouldFloat }

            /// Test readout: the floating label's current text color (reflects error / focus / neutral).
            var floatingLabelColorForTest: UIColor { floatingLabel.textColor }

            /// Test readout: the floating label's current frame (to assert trailing room / position).
            var floatingLabelFrameForTest: CGRect { floatingLabel.frame }
        #endif
    }
#endif
