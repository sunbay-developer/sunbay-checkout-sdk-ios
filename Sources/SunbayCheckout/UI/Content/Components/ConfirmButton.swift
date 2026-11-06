#if canImport(UIKit)
    import QuartzCore
    import UIKit

    /// The primary call-to-action button and its visible-status carrier (design §5).
    ///
    /// `ConfirmButton` owns four statuses that mirror the content state machine's user-facing phases:
    /// `enabled` (interactive orange CTA), `disabled` (dimmed, non-interactive), `processing` (spinner,
    /// non-interactive), and `succeeded` (a ring→checkmark animation that resolves a completion after a
    /// short display window). It never talks to Core; tapping while `enabled` simply fires `onTap`.
    ///
    /// The success animation is ported conceptually from Stripe's `ConfirmButton.animateSuccess`: a
    /// `CAShapeLayer` draws a circular ring stroked in, followed by a checkmark path stroked in. Under
    /// `UIAccessibility.isReduceMotionEnabled` the shapes are shown in their final state without the
    /// stroke animation, and the spinner is not spun — but the timing contract is unchanged.
    ///
    /// Timing contract: regardless of `animated`, `update(status: .succeeded)` calls its `completion`
    /// after `successDisplayDuration`. `minimumFlightTime` is exposed for the caller (the content VC)
    /// to avoid a processing-state flicker; the button itself does not gate on it.
    ///
    /// iOS-only: gated by `#if canImport(UIKit)`; does not compile under the macOS host (`swift test`).
    final class ConfirmButton: UIControl {
        /// The visible status of the button.
        enum Status {
            /// Interactive CTA (brand background, title in the primary-button text color).
            case enabled
            /// Dimmed, non-interactive (e.g. the form is incomplete).
            case disabled
            /// Confirm in flight: spinner shown, non-interactive.
            case processing
            /// Confirmed: ring→checkmark animation, then `completion` after `successDisplayDuration`.
            case succeeded
        }

        /// Minimum time the `processing` state should be shown by the caller to avoid a flicker.
        ///
        /// The button does not enforce this itself; the content VC uses it to pace the processing
        /// phase before applying the outcome (design §3.2).
        static var minimumFlightTime: TimeInterval = 0.5

        /// How long the success animation stays on screen before `completion` fires.
        static var successDisplayDuration: TimeInterval = 0.8

        /// Invoked when the button is tapped while `enabled`.
        var onTap: (() -> Void)?

        /// Whether the `enabled` status is rendered dimmed with the `.notEnabled` accessibility trait
        /// while STILL delivering taps.
        ///
        /// Used for an incomplete form: the button looks disabled, yet a tap must reach `onTap` so the
        /// owner can surface the field error (a truly disabled control receives no touches). Has no
        /// effect on the other statuses.
        var appearsDisabled = false {
            didSet {
                guard appearsDisabled != oldValue, status == .enabled else { return }
                apply(status: .enabled)
            }
        }

        // MARK: - Private state

        private let appearance: ResolvedAppearance
        private var status: Status = .enabled
        private var title: String = ""

        private let titleLabel = UILabel()
        private lazy var spinner: UIActivityIndicatorView = {
            let s = UIActivityIndicatorView(style: .medium)
            s.hidesWhenStopped = true
            s.color = appearance.primaryButtonText
            s.translatesAutoresizingMaskIntoConstraints = false
            return s
        }()

        /// Layer that draws the success ring then checkmark.
        private var successLayer: CAShapeLayer?

        // MARK: - Init

        /// Creates a confirm button with resolved appearance tokens.
        ///
        /// - Parameter appearance: The resolved appearance providing the button background / text color,
        ///   corner radius, CTA font, and success color.
        init(appearance: ResolvedAppearance) {
            self.appearance = appearance
            super.init(frame: .zero)
            configureSubviews()
            apply(status: .enabled)
        }

        @available(*, unavailable)
        required init?(coder: NSCoder) {
            fatalError("init(coder:) is not supported")
        }

        // MARK: - Public API

        #if DEBUG
            /// Test seam: delivers a tap the way UIKit would (only when the control is enabled), running
            /// the same handler as a real `.touchUpInside`. Needs no `UIApplication`, so it works in
            /// host-less unit tests.
            func simulateTouchUpInsideForTest() {
                guard isEnabled else { return }
                handleTap()
            }

            /// Test readout: the current accessibility traits.
            var accessibilityTraitsForTest: UIAccessibilityTraits { accessibilityTraits }
        #endif

        /// Sets the button's title (e.g. the localized `Pay %@` amount string).
        ///
        /// - Parameter title: The title text.
        func setTitle(_ title: String) {
            self.title = title
            titleLabel.text = title
        }

        #if DEBUG
            /// Test readout: the current title text.
            var titleForTest: String { title }
        #endif

        /// Updates the button's visible status.
        ///
        /// - Parameters:
        ///   - status: The new status.
        ///   - animated: Whether the success transition should animate. The completion timing is
        ///     honored regardless of this flag (see `successDisplayDuration`).
        ///   - completion: Called after `successDisplayDuration` when `status == .succeeded`; ignored
        ///     for the other statuses.
        func update(status: Status, animated: Bool, completion: (() -> Void)? = nil) {
            self.status = status
            apply(status: status)

            guard status == .succeeded else { return }
            animateSuccess(animated: animated)
            DispatchQueue.main.asyncAfter(deadline: .now() + Self.successDisplayDuration) {
                completion?()
            }
        }

        // MARK: - Status application

        /// Applies the visual + interaction changes for a status.
        private func apply(status: Status) {
            switch status {
            case .enabled:
                isEnabled = true
                spinner.stopAnimating()
                removeSuccessLayer()
                titleLabel.isHidden = false
                backgroundColor = appearance.primaryButtonBackground
                titleLabel.textColor = appearance.primaryButtonText
                alpha = appearsDisabled ? 0.4 : 1.0
                accessibilityTraits = appearsDisabled ? [.button, .notEnabled] : .button
            case .disabled:
                isEnabled = false
                spinner.stopAnimating()
                removeSuccessLayer()
                titleLabel.isHidden = false
                backgroundColor = appearance.primaryButtonBackground
                titleLabel.textColor = appearance.primaryButtonText
                alpha = 0.4
                accessibilityTraits = [.button, .notEnabled]
            case .processing:
                isEnabled = false
                removeSuccessLayer()
                titleLabel.isHidden = true
                backgroundColor = appearance.primaryButtonBackground
                alpha = 1.0
                accessibilityTraits = .button
                // Always show the spinner: it is the in-flight affordance. Reduced motion does not
                // suppress it (the indicator still signals processing); only decorative motion elsewhere honors it.
                spinner.startAnimating()
            case .succeeded:
                isEnabled = false
                spinner.stopAnimating()
                titleLabel.isHidden = true
                // Background is transitioned to the success color by `animateSuccess` (morphed when
                // animated, set directly under reduced motion). Leaving it unchanged here avoids a
                // one-frame flash of the brand background before the morph begins.
                alpha = 1.0
                accessibilityTraits = .button
            }
        }

        // MARK: - Success animation (green fill + white checkmark)

        /// Transforms the button into a success "check button": the brand background morphs to the
        /// success color and a large white checkmark is drawn on top.
        ///
        /// When animated, the background crossfades to green while the checkmark pops in (scale +
        /// fade) so the CTA appears to transform in place rather than being replaced. Under reduced
        /// motion the final state (green fill + fully drawn checkmark) is shown without motion.
        private func animateSuccess(animated: Bool) {
            removeSuccessLayer()

            // The checkmark occupies a generous share of the button height so the icon reads large.
            let side = min(bounds.height, 44) * 0.8

            let shape = CAShapeLayer()
            shape.fillColor = UIColor.clear.cgColor
            shape.strokeColor = UIColor.white.cgColor
            shape.lineWidth = max(3, side * 0.11)
            shape.lineCap = .round
            shape.lineJoin = .round
            shape.path = checkmarkPath(side: side).cgPath
            layer.addSublayer(shape)
            successLayer = shape

            layoutSuccessLayer(shape, side: side)

            let reduceMotion = UIAccessibility.isReduceMotionEnabled
            guard animated, !reduceMotion else {
                // Final state only: green fill + fully drawn checkmark, no motion.
                backgroundColor = appearance.success
                shape.strokeEnd = 1
                return
            }

            // Phase 1: morph the background from the brand color to the success color.
            UIView.animate(withDuration: 0.25, delay: 0, options: [.curveEaseInOut]) {
                self.backgroundColor = self.appearance.success
            }

            // Phase 2: pop the checkmark in (scale from 0.6 → 1 while fading and stroking in).
            let fade = CABasicAnimation(keyPath: "opacity")
            fade.fromValue = 0
            fade.toValue = 1

            let stroke = CABasicAnimation(keyPath: "strokeEnd")
            stroke.fromValue = 0
            stroke.toValue = 1

            let scale = CABasicAnimation(keyPath: "transform.scale")
            scale.fromValue = 0.6
            scale.toValue = 1
            scale.timingFunction = CAMediaTimingFunction(controlPoints: 0.2, 0.9, 0.3, 1.3) // slight overshoot

            let group = CAAnimationGroup()
            group.animations = [fade, stroke, scale]
            group.duration = 0.3
            group.beginTime = CACurrentMediaTime() + 0.15 // start as the background morph settles
            group.fillMode = .backwards

            shape.strokeEnd = 1
            shape.add(group, forKey: "check")
        }

        /// Centers the success shape layer in the button bounds and anchors it for a centered scale.
        private func layoutSuccessLayer(_ shape: CAShapeLayer, side: CGFloat) {
            shape.bounds = CGRect(x: 0, y: 0, width: side, height: side)
            shape.position = CGPoint(x: bounds.midX, y: bounds.midY)
        }

        /// A checkmark path in a `side`×`side` box.
        private func checkmarkPath(side: CGFloat) -> UIBezierPath {
            let path = UIBezierPath()
            path.move(to: CGPoint(x: side * 0.22, y: side * 0.52))
            path.addLine(to: CGPoint(x: side * 0.42, y: side * 0.72))
            path.addLine(to: CGPoint(x: side * 0.78, y: side * 0.30))
            return path
        }

        /// Removes the success shape layer, if any.
        private func removeSuccessLayer() {
            successLayer?.removeFromSuperlayer()
            successLayer = nil
        }

        // MARK: - Layout

        /// Builds the title label + spinner and wires the touch target.
        private func configureSubviews() {
            layer.cornerRadius = appearance.primaryButtonCornerRadius
            clipsToBounds = true
            isAccessibilityElement = true
            accessibilityTraits = .button

            titleLabel.font = appearance.ctaFont
            titleLabel.textAlignment = .center
            titleLabel.textColor = appearance.primaryButtonText
            titleLabel.translatesAutoresizingMaskIntoConstraints = false
            addSubview(titleLabel)
            addSubview(spinner)

            NSLayoutConstraint.activate([
                titleLabel.centerXAnchor.constraint(equalTo: centerXAnchor),
                titleLabel.centerYAnchor.constraint(equalTo: centerYAnchor),
                titleLabel.leadingAnchor.constraint(greaterThanOrEqualTo: leadingAnchor, constant: 12),
                titleLabel.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -12),
                spinner.centerXAnchor.constraint(equalTo: centerXAnchor),
                spinner.centerYAnchor.constraint(equalTo: centerYAnchor),
                heightAnchor.constraint(greaterThanOrEqualToConstant: 52),
            ])
            // Resolve the button's height to its 52pt minimum unless content (Dynamic Type) needs more.
            // Without a preferred value the `>= 52` leaves the height a free variable; when the button is
            // visible inside the fixed bottom bar (now the case on the COF home page, which shows Pay for
            // the pre-selected card), that free variable makes the scroll/bottom-bar split ambiguous.
            let preferredHeight = heightAnchor.constraint(equalToConstant: 52)
            preferredHeight.priority = .defaultLow
            preferredHeight.isActive = true

            addTarget(self, action: #selector(handleTap), for: .touchUpInside)
        }

        override func layoutSubviews() {
            super.layoutSubviews()
            if let successLayer {
                layoutSuccessLayer(successLayer, side: successLayer.bounds.width)
            }
        }

        /// Fires `onTap` when the button is tapped while interactive (including the dimmed
        /// `appearsDisabled` presentation, which still reports taps).
        @objc private func handleTap() {
            guard status == .enabled else { return }
            onTap?()
        }

        // MARK: - Accessibility

        override var accessibilityLabel: String? {
            get { title }
            set { super.accessibilityLabel = newValue }
        }
    }
#endif
