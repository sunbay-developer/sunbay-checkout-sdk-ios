#if canImport(UIKit)
    import UIKit

    /// Direction of an in-sheet page switch.
    enum PageDirection {
        /// Going deeper (e.g. home → new card): new content enters from the trailing edge.
        case forward
        /// Going back (e.g. new card → home): new content enters from the leading edge.
        case backward
    }

    /// Reusable forward/backward page transition for any page swap inside the bottom sheet.
    ///
    /// Usage: wrap the page switch (the code that flips `isHidden` / swaps content) in `perform`.
    /// The helper snapshots the current content before the change, lets the caller apply the final
    /// layout immediately (so sheet-height reporting is unaffected), then animates the snapshot out
    /// and the live content in. It never touches the view hierarchy structure of the pages themselves.
    ///
    /// Reduce Motion downgrades the slide to a cross-fade. Pass `animated: false` (or disable via
    /// `Appearance.pageTransitionsEnabled`) to apply the change instantly.
    @MainActor
    enum PageTransition {
        private static let duration: TimeInterval = 0.3
        /// The outgoing page travels this fraction of the width (a parallax feel); incoming travels 100%.
        private static let outgoingTravelFraction: CGFloat = 0.3
        private static let snapshotTag = 0x5342_5054  // "SBPT"

        /// Cross-dissolves fixed chrome (e.g. the header title + back button) while `change` runs, so it
        /// stays in step with a page transition. Applies `change` instantly when not animated or when
        /// the view is not on screen.
        static func crossDissolve(_ view: UIView, animated: Bool, change: @escaping () -> Void) {
            guard animated, view.window != nil else {
                change()
                return
            }
            UIView.transition(
                with: view, duration: duration, options: [.transitionCrossDissolve, .allowUserInteraction],
                animations: change)
        }

        /// Runs `change` with a transition.
        ///
        /// - Parameters:
        ///   - container: The view that clips and hosts the pages (e.g. the scroll view).
        ///   - content: The live view whose appearance changes (e.g. the root stack of pages).
        ///   - direction: Forward or backward.
        ///   - animated: When `false`, `change` runs with no animation.
        ///   - change: Applies the final page state synchronously.
        static func perform(
            in container: UIView,
            content: UIView,
            direction: PageDirection,
            animated: Bool,
            change: () -> Void
        ) {
            // Cancel any transition still in flight.
            container.subviews.filter { $0.tag == snapshotTag }.forEach { $0.removeFromSuperview() }
            content.layer.removeAllAnimations()
            content.transform = .identity
            content.alpha = 1

            guard animated, container.window != nil, container.bounds.width > 0,
                let snapshot = content.snapshotView(afterScreenUpdates: false)
            else {
                change()
                return
            }

            snapshot.tag = snapshotTag
            snapshot.frame = container.convert(content.bounds, from: content)
            snapshot.isUserInteractionEnabled = false
            let wasClipping = container.clipsToBounds
            container.clipsToBounds = true
            container.addSubview(snapshot)

            change()
            container.layoutIfNeeded()

            let width = container.bounds.width
            let sign: CGFloat = direction == .forward ? 1 : -1
            let slide = !UIAccessibility.isReduceMotionEnabled

            content.alpha = 0
            if slide { content.transform = CGAffineTransform(translationX: sign * width, y: 0) }

            UIView.animate(
                withDuration: duration, delay: 0, options: [.curveEaseInOut, .allowUserInteraction],
                animations: {
                    content.alpha = 1
                    content.transform = .identity
                    snapshot.alpha = 0
                    if slide {
                        snapshot.transform = CGAffineTransform(
                            translationX: -sign * width * outgoingTravelFraction, y: 0)
                    }
                },
                completion: { _ in
                    snapshot.removeFromSuperview()
                    container.clipsToBounds = wasClipping
                })
        }
    }
#endif
