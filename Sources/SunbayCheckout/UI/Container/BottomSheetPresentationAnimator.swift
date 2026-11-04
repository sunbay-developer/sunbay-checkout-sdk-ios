#if canImport(UIKit)
    import UIKit

    /// Slide-up / slide-down transition for the custom bottom sheet.
    ///
    /// Uses a spring `UIViewPropertyAnimator` (duration 0.5) animating a vertical translation of the
    /// presented view, which composes with its Auto Layout constraints (no frame fighting). With
    /// Reduce Motion enabled it cross-dissolves instead of sliding. The presented view's
    /// interaction is disabled while it moves and re-enabled when the transition ends.
    final class BottomSheetPresentationAnimator: NSObject, UIViewControllerAnimatedTransitioning {
        enum Style {
            case presentation
            case dismissal
        }

        /// Transition duration in seconds (Stripe parity).
        static let duration: TimeInterval = 0.5
        /// Cross-dissolve duration used with Reduce Motion.
        static let reducedMotionDuration: TimeInterval = 0.25

        private let style: Style

        init(style: Style) {
            self.style = style
            super.init()
        }

        func transitionDuration(using transitionContext: UIViewControllerContextTransitioning?) -> TimeInterval {
            UIAccessibility.isReduceMotionEnabled ? Self.reducedMotionDuration : Self.duration
        }

        func animateTransition(using transitionContext: UIViewControllerContextTransitioning) {
            switch style {
            case .presentation: animatePresentation(transitionContext)
            case .dismissal: animateDismissal(transitionContext)
            }
        }

        private func makeAnimator() -> UIViewPropertyAnimator {
            if UIAccessibility.isReduceMotionEnabled {
                return UIViewPropertyAnimator(
                    duration: Self.reducedMotionDuration, timingParameters: UICubicTimingParameters(animationCurve: .easeInOut))
            }
            return UIViewPropertyAnimator(duration: Self.duration, timingParameters: UISpringTimingParameters())
        }

        private func animatePresentation(_ context: UIViewControllerContextTransitioning) {
            guard let toVC = context.viewController(forKey: .to) else {
                context.completeTransition(false)
                return
            }
            let sheetView: UIView = context.view(forKey: .to) ?? toVC.view
            let container = context.containerView
            // Lay out once and apply the measured content height so the sheet enters at its final size.
            (toVC.presentationController as? BottomSheetPresentationController)?.flushPendingHeight()
            container.layoutIfNeeded()

            let reduceMotion = UIAccessibility.isReduceMotionEnabled
            if reduceMotion {
                sheetView.alpha = 0
            } else {
                sheetView.transform = CGAffineTransform(translationX: 0, y: container.bounds.height)
            }
            sheetView.isUserInteractionEnabled = false

            let animator = makeAnimator()
            animator.addAnimations {
                sheetView.transform = .identity
                sheetView.alpha = 1
            }
            animator.addCompletion { _ in
                sheetView.isUserInteractionEnabled = true
                context.completeTransition(!context.transitionWasCancelled)
            }
            animator.startAnimation()
        }

        private func animateDismissal(_ context: UIViewControllerContextTransitioning) {
            guard let fromVC = context.viewController(forKey: .from) else {
                context.completeTransition(false)
                return
            }
            let sheetView: UIView = context.view(forKey: .from) ?? fromVC.view
            let container = context.containerView
            let reduceMotion = UIAccessibility.isReduceMotionEnabled
            sheetView.isUserInteractionEnabled = false

            let animator = makeAnimator()
            animator.addAnimations {
                if reduceMotion {
                    sheetView.alpha = 0
                } else {
                    sheetView.transform = CGAffineTransform(translationX: 0, y: container.bounds.height)
                }
            }
            animator.addCompletion { _ in
                let cancelled = context.transitionWasCancelled
                if cancelled {
                    sheetView.transform = .identity
                    sheetView.alpha = 1
                    sheetView.isUserInteractionEnabled = true
                } else {
                    sheetView.removeFromSuperview()
                    sheetView.transform = .identity
                    sheetView.alpha = 1
                    sheetView.isUserInteractionEnabled = true
                }
                context.completeTransition(!cancelled)
            }
            animator.startAnimation()
        }
    }
#endif
