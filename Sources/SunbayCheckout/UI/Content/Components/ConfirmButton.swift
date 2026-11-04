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
                backgroundColor = appearance.primaryButtonBackground
                alpha = 1.0
                accessibilityTraits = .button
            }
        }

        // MARK: - Success animation (ported conceptually from Stripe's animateSuccess)

        /// Draws the ring→checkmark success indicator.
        ///
        /// A `CAShapeLayer` strokes a full circle, then a checkmark path, using the resolved success
        /// color. Under reduced motion both shapes are shown fully drawn without the stroke animation.
        private func animateSuccess(animated: Bool) {
            removeSuccessLayer()

            let side: CGFloat = 20
            let shape = CAShapeLayer()
            shape.fillColor = UIColor.clear.cgColor
            shape.strokeColor = appearance.success.cgColor
            shape.lineWidth = 2
            shape.lineCap = .round
            shape.lineJoin = .round
            layer.addSublayer(shape)
            successLayer = shape

            layoutSuccessLayer(shape, side: side)

            let reduceMotion = UIAccessibility.isReduceMotionEnabled
            guard animated, !reduceMotion else {
                // Final state only: show the checkmark path fully drawn.
                shape.path = checkmarkPath(side: side).cgPath
                shape.strokeEnd = 1
                return
            }

            // Phase 1: stroke the ring in.
            shape.path = ringPath(side: side).cgPath
            let ring = CABasicAnimation(keyPath: "strokeEnd")
            ring.fromValue = 0
            ring.toValue = 1
            ring.duration = 0.25
            ring.timingFunction = CAMediaTimingFunction(name: .easeOut)
            shape.add(ring, forKey: "ring")

            // Phase 2: swap to the checkmark and stroke it in.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [weak self] in
                guard let self, self.successLayer === shape else { return }
                shape.path = self.checkmarkPath(side: side).cgPath
                let check = CABasicAnimation(keyPath: "strokeEnd")
                check.fromValue = 0
                check.toValue = 1
                check.duration = 0.2
                check.timingFunction = CAMediaTimingFunction(name: .easeOut)
                shape.strokeEnd = 1
                shape.add(check, forKey: "check")
            }
        }

        /// Centers the success shape layer in the button bounds.
        private func layoutSuccessLayer(_ shape: CAShapeLayer, side: CGFloat) {
            let origin = CGPoint(x: (bounds.width - side) / 2, y: (bounds.height - side) / 2)
            shape.frame = CGRect(origin: origin, size: CGSize(width: side, height: side))
        }

        /// A circular ring path in a `side`×`side` box.
        private func ringPath(side: CGFloat) -> UIBezierPath {
            UIBezierPath(ovalIn: CGRect(x: 1, y: 1, width: side - 2, height: side - 2))
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
