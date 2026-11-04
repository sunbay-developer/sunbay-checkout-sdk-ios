#if canImport(UIKit)
    import UIKit

    /// Installs and maintains the Auto Layout constraints of the custom bottom sheet's presented view.
    ///
    /// Kept separate from `BottomSheetPresentationController` so the constraint installation can be
    /// exercised with an arbitrary container/presented view pair (the SwiftPM test bundle has no host
    /// app, so a truly presented sheet cannot be laid out there).
    ///
    /// Layout contract:
    /// - leading / trailing: the container's safe-area guide (full width on iPhone portrait; inset by
    ///   the side safe area in landscape),
    /// - bottom: the container's bottom edge (under the home indicator — the content adds the bottom
    ///   safe-area inset itself) minus the keyboard overlap,
    /// - height: an explicit constant computed by `BottomSheetGeometry` at priority 999 (see below),
    /// - corners: top two only, radius `BottomSheetGeometry.cornerRadius`, `masksToBounds`.
    ///
    /// This type only mutates constraint constants; animating a change is the caller's job (it wraps
    /// `containerView.layoutIfNeeded()` in an animation block).
    final class BottomSheetLayout {
        /// The sizing policy applied to the content height.
        let policy: BottomSheetGeometry.Policy
        /// Top-corner radius applied to the presented view.
        let cornerRadius: CGFloat

        /// The latest total content height reported by the content (`0` until measured).
        private(set) var contentHeight: CGFloat
        /// How far the keyboard currently covers the container's bottom edge.
        private(set) var keyboardOverlap: CGFloat = 0
        /// The explicit height constraint (nil before `install`).
        private(set) var heightConstraint: NSLayoutConstraint?
        /// The bottom-pin constraint; its constant is `-keyboardOverlap`.
        private(set) var bottomConstraint: NSLayoutConstraint?

        private weak var containerView: UIView?
        private weak var presentedView: UIView?

        init(policy: BottomSheetGeometry.Policy, appearanceCornerRadius: CGFloat, contentHeight: CGFloat = 0) {
            self.policy = policy
            self.cornerRadius = BottomSheetGeometry.cornerRadius(appearanceCornerRadius: appearanceCornerRadius)
            self.contentHeight = contentHeight
        }

        /// Priority of the height constraint: `.required - 1`.
        ///
        /// The geometry result can legitimately fall below the content's own minimum layout height
        /// (e.g. `fixedFraction(0.1)`, a tiny `maxHeightFraction`, or landscape with the keyboard up
        /// on a small phone). A `.required` height would then be unsatisfiable against the content's
        /// required constraints and UIKit would break one at random. At 999 the content's required
        /// constraints always win, so the sheet degrades to the content's minimum height instead of
        /// producing a layout conflict. This is preferred over a hard-coded floor constant, which
        /// would have to guess the content's real minimum.
        static let heightPriority = UILayoutPriority(UILayoutPriority.required.rawValue - 1)

        /// Adds `presentedView` to `containerView` and activates the sheet constraints.
        func install(presentedView: UIView, in containerView: UIView) {
            self.containerView = containerView
            self.presentedView = presentedView
            presentedView.translatesAutoresizingMaskIntoConstraints = false
            containerView.addSubview(presentedView)

            let bottom = presentedView.bottomAnchor.constraint(equalTo: containerView.bottomAnchor)
            bottom.priority = .required
            let height = presentedView.heightAnchor.constraint(equalToConstant: computedHeight())
            height.priority = Self.heightPriority
            bottomConstraint = bottom
            heightConstraint = height

            NSLayoutConstraint.activate([
                presentedView.leadingAnchor.constraint(equalTo: containerView.safeAreaLayoutGuide.leadingAnchor),
                presentedView.trailingAnchor.constraint(equalTo: containerView.safeAreaLayoutGuide.trailingAnchor),
                bottom,
                height,
            ])
            applyCorners()
        }

        /// Top corners only, so the sheet stays edge-attached at the bottom.
        func applyCorners() {
            guard let layer = presentedView?.layer else { return }
            layer.maskedCorners = [.layerMinXMinYCorner, .layerMaxXMinYCorner]
            layer.cornerRadius = cornerRadius
            layer.masksToBounds = true
        }

        /// Records a new content height. Returns whether it changed (the constraints are not touched).
        @discardableResult
        func setContentHeight(_ height: CGFloat) -> Bool {
            let sanitized = height.isFinite ? max(0, height) : 0
            guard sanitized != contentHeight else { return false }
            contentHeight = sanitized
            return true
        }

        /// Records a new keyboard overlap. Returns whether it changed (the constraints are not touched).
        @discardableResult
        func setKeyboardOverlap(_ overlap: CGFloat) -> Bool {
            let sanitized = overlap.isFinite ? max(0, overlap) : 0
            guard sanitized != keyboardOverlap else { return false }
            keyboardOverlap = sanitized
            return true
        }

        /// The sheet height for the current inputs and container measurements.
        func computedHeight() -> CGFloat {
            guard let containerView else { return 0 }
            return BottomSheetGeometry.sheetHeight(
                containerHeight: containerView.bounds.height,
                safeAreaTop: containerView.safeAreaInsets.top,
                keyboardOverlap: keyboardOverlap,
                contentHeight: contentHeight,
                policy: policy)
        }

        /// Writes the current inputs into the constraint constants. Returns whether anything changed.
        @discardableResult
        func applyConstants() -> Bool {
            var changed = false
            let height = computedHeight()
            if let heightConstraint, heightConstraint.constant != height {
                heightConstraint.constant = height
                changed = true
            }
            let bottom = -keyboardOverlap
            if let bottomConstraint, bottomConstraint.constant != bottom {
                bottomConstraint.constant = bottom
                changed = true
            }
            return changed
        }
    }

    extension BottomSheetGeometry.Policy {
        /// Maps the public `Appearance.SheetSizing` onto the pure geometry policy.
        init(_ sizing: Appearance.SheetSizing) {
            let mode: Mode
            switch sizing.mode {
            case .adaptive: mode = .adaptive
            case let .fixedFraction(fraction): mode = .fixedFraction(fraction)
            case .large: mode = .large
            }
            self.init(minHeight: sizing.minHeight, maxHeightFraction: sizing.maxHeightFraction, mode: mode)
        }
    }
#endif
