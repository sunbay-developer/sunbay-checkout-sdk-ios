#if canImport(UIKit)
    import UIKit

    /// The custom iPhone presentation for the payment sheet (Stripe parity).
    ///
    /// It sits between the presenting and presented view controllers and:
    /// - adds a black 40% dimming view behind the sheet; tapping it reports `onBackdropTap`
    ///   (the owner decides whether a cancel is currently allowed),
    /// - pins the presented view full-width and edge-attached to the bottom through
    ///   `BottomSheetLayout` (explicit height from `BottomSheetGeometry`, top corners only),
    /// - re-evaluates the height when the content reports a new height, when the container resizes
    ///   (rotation, safe-area change) and when the keyboard changes its overlap.
    ///
    /// There is deliberately no grabber, no drag-to-dismiss and no scaling of the presenting view.
    final class BottomSheetPresentationController: UIPresentationController {
        // MARK: - Public surface

        /// Called when the dimming backdrop is tapped and no transition animation is running.
        var onBackdropTap: (() -> Void)?

        /// Called after a keyboard-driven height change settles (the owner scrolls the focused field
        /// into view).
        var onKeyboardSettled: (() -> Void)?

        /// The constraint installer; exposed read-only for tests.
        let layout: BottomSheetLayout

        /// Whether a present/dismiss transition animation is in flight (settable for tests only).
        var isTransitioning = false

        // MARK: - Views / state

        let dimmingView = UIView()
        private var heightRefreshScheduled = false

        // MARK: - Init

        init(
            presentedViewController: UIViewController,
            presenting presentingViewController: UIViewController?,
            layout: BottomSheetLayout
        ) {
            self.layout = layout
            super.init(presentedViewController: presentedViewController, presenting: presentingViewController)
            dimmingView.backgroundColor = UIColor.black.withAlphaComponent(Self.dimmingAlpha)
            dimmingView.alpha = 0
            dimmingView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
            // The backdrop is not an accessibility element: the ✕ and the Escape gesture dismiss.
            dimmingView.isAccessibilityElement = false
            dimmingView.addGestureRecognizer(
                UITapGestureRecognizer(target: self, action: #selector(didTapDimmingView)))
        }

        deinit {
            NotificationCenter.default.removeObserver(self)
        }

        /// Backdrop opacity (black).
        static let dimmingAlpha: CGFloat = 0.4

        // MARK: - Presentation lifecycle

        override func presentationTransitionWillBegin() {
            guard let containerView, let sheetView = presentedViewController.view else { return }
            dimmingView.frame = containerView.bounds
            containerView.addSubview(dimmingView)
            layout.install(presentedView: sheetView, in: containerView)
            sheetView.accessibilityViewIsModal = true
            registerKeyboardObservers()

            isTransitioning = true
            if let coordinator = presentedViewController.transitionCoordinator {
                coordinator.animate(
                    alongsideTransition: { [weak self] _ in
                        self?.dimmingView.alpha = 1
                        self?.presentedViewController.setNeedsStatusBarAppearanceUpdate()
                    },
                    completion: { [weak self] _ in self?.isTransitioning = false })
            } else {
                dimmingView.alpha = 1
                isTransitioning = false
            }
        }

        override func presentationTransitionDidEnd(_ completed: Bool) {
            isTransitioning = false
            guard !completed else { return }
            dimmingView.removeFromSuperview()
            NotificationCenter.default.removeObserver(self)
        }

        override func dismissalTransitionWillBegin() {
            isTransitioning = true
            if let coordinator = presentedViewController.transitionCoordinator {
                coordinator.animate(
                    alongsideTransition: { [weak self] _ in
                        self?.dimmingView.alpha = 0
                        self?.presentingViewController.setNeedsStatusBarAppearanceUpdate()
                    },
                    completion: { [weak self] _ in self?.isTransitioning = false })
            } else {
                dimmingView.alpha = 0
                isTransitioning = false
            }
        }

        override func dismissalTransitionDidEnd(_ completed: Bool) {
            isTransitioning = false
            guard completed else { return }
            dimmingView.removeFromSuperview()
            NotificationCenter.default.removeObserver(self)
        }

        override func containerViewWillLayoutSubviews() {
            super.containerViewWillLayoutSubviews()
            // Container resized (rotation / safe-area change): keep corners and height in sync. Inside
            // a rotation this runs in the transition's animation context, so the change animates.
            layout.applyCorners()
            layout.applyConstants()
        }

        override func viewWillTransition(
            to size: CGSize, with coordinator: UIViewControllerTransitionCoordinator
        ) {
            super.viewWillTransition(to: size, with: coordinator)
            coordinator.animate(alongsideTransition: { [weak self] _ in
                self?.layout.applyCorners()
            })
        }

        // MARK: - Height updates

        /// Feeds a new total content height. The (coalesced) update animates with the transition
        /// spring; before the entrance animation starts the animator flushes it synchronously.
        func setContentHeight(_ height: CGFloat) {
            guard layout.setContentHeight(height) else { return }
            guard !heightRefreshScheduled else { return }
            heightRefreshScheduled = true
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.heightRefreshScheduled = false
                self.refreshHeight(animated: true)
            }
        }

        /// Applies any pending height synchronously and without animation (used right before the
        /// entrance animation so the sheet starts at its measured height).
        func flushPendingHeight() {
            heightRefreshScheduled = false
            layout.applyConstants()
            containerView?.layoutIfNeeded()
        }

        /// Recomputes the height constant; animates the layout change with the transition spring
        /// unless Reduce Motion is on or the view is not on screen yet.
        func refreshHeight(animated: Bool) {
            guard let containerView else { return }
            guard layout.applyConstants() else { return }
            if animated, containerView.window != nil, !UIAccessibility.isReduceMotionEnabled {
                let animator = UIViewPropertyAnimator(
                    duration: BottomSheetPresentationAnimator.duration,
                    timingParameters: UISpringTimingParameters())
                animator.addAnimations { containerView.layoutIfNeeded() }
                animator.startAnimation()
            } else {
                containerView.layoutIfNeeded()
            }
        }

        // MARK: - Keyboard

        private func registerKeyboardObservers() {
            let center = NotificationCenter.default
            center.removeObserver(self)
            center.addObserver(
                self, selector: #selector(keyboardWillChangeFrame(_:)),
                name: UIResponder.keyboardWillChangeFrameNotification, object: nil)
            center.addObserver(
                self, selector: #selector(keyboardWillHide(_:)),
                name: UIResponder.keyboardWillHideNotification, object: nil)
        }

        @objc private func keyboardWillChangeFrame(_ notification: Notification) {
            guard let containerView,
                let endFrame = notification.userInfo?[UIResponder.keyboardFrameEndUserInfoKey] as? CGRect
            else { return }
            let space: UICoordinateSpace = containerView.window?.screen.coordinateSpace ?? UIScreen.main.coordinateSpace
            let local = containerView.convert(endFrame, from: space)
            let overlap = BottomSheetGeometry.keyboardOverlap(containerBounds: containerView.bounds, keyboardFrame: local)
            applyKeyboardOverlap(overlap, userInfo: notification.userInfo)
        }

        @objc private func keyboardWillHide(_ notification: Notification) {
            applyKeyboardOverlap(0, userInfo: notification.userInfo)
        }

        /// Lifts the sheet by `overlap`, shrinks its available height and animates both with the
        /// keyboard's own duration and curve.
        func applyKeyboardOverlap(_ overlap: CGFloat, userInfo: [AnyHashable: Any]? = nil) {
            guard let containerView, layout.setKeyboardOverlap(overlap) else { return }
            layout.applyConstants()
            let duration = (userInfo?[UIResponder.keyboardAnimationDurationUserInfoKey] as? Double) ?? 0.25
            let curveRaw = (userInfo?[UIResponder.keyboardAnimationCurveUserInfoKey] as? Int)
                ?? UIView.AnimationCurve.easeInOut.rawValue
            if duration > 0, containerView.window != nil {
                UIView.animate(
                    withDuration: duration, delay: 0,
                    options: [UIView.AnimationOptions(rawValue: UInt(curveRaw << 16)), .beginFromCurrentState],
                    animations: { containerView.layoutIfNeeded() },
                    completion: { [weak self] _ in self?.onKeyboardSettled?() })
            } else {
                containerView.layoutIfNeeded()
                onKeyboardSettled?()
            }
        }

        // MARK: - Backdrop

        @objc private func didTapDimmingView() {
            // The entrance/exit animation is not cleanly interruptible: ignore taps until it ends.
            // Running layer animations on the sheet (height changes) are treated the same way.
            guard !isTransitioning else { return }
            guard presentedViewController.view.layer.animationKeys()?.isEmpty ?? true else { return }
            onBackdropTap?()
        }

        /// Test seam: delivers a backdrop tap exactly as the recognizer would.
        func simulateBackdropTapForTest() { didTapDimmingView() }
    }
#endif
