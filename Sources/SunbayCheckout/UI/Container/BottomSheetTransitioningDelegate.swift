#if canImport(UIKit)
    import UIKit

    /// Supplies the custom presentation controller and slide animators for the iPhone bottom sheet.
    ///
    /// `UIViewController.transitioningDelegate` is weak, so the container retains an instance of this
    /// type for as long as it lives.
    final class BottomSheetTransitioningDelegate: NSObject, UIViewControllerTransitioningDelegate {
        /// Builds the layout installer for a new presentation (reads the latest content height).
        private let makeLayout: () -> BottomSheetLayout
        /// Wired onto each created presentation controller.
        private let onBackdropTap: () -> Void
        private let onKeyboardSettled: () -> Void

        init(
            makeLayout: @escaping () -> BottomSheetLayout,
            onBackdropTap: @escaping () -> Void,
            onKeyboardSettled: @escaping () -> Void
        ) {
            self.makeLayout = makeLayout
            self.onBackdropTap = onBackdropTap
            self.onKeyboardSettled = onKeyboardSettled
            super.init()
        }

        func presentationController(
            forPresented presented: UIViewController,
            presenting: UIViewController?,
            source: UIViewController
        ) -> UIPresentationController? {
            let controller = BottomSheetPresentationController(
                presentedViewController: presented, presenting: presenting, layout: makeLayout())
            controller.onBackdropTap = onBackdropTap
            controller.onKeyboardSettled = onKeyboardSettled
            return controller
        }

        func animationController(
            forPresented presented: UIViewController,
            presenting: UIViewController,
            source: UIViewController
        ) -> UIViewControllerAnimatedTransitioning? {
            BottomSheetPresentationAnimator(style: .presentation)
        }

        func animationController(forDismissed dismissed: UIViewController) -> UIViewControllerAnimatedTransitioning? {
            BottomSheetPresentationAnimator(style: .dismissal)
        }
    }
#endif
