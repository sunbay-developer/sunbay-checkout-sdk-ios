#if canImport(UIKit)
    import QuartzCore
    import UIKit

    /// Shared helper that re-resolves a `CALayer`'s `cgColor`-based colors against the view's current
    /// trait collection (design §4.3).
    ///
    /// `CALayer.borderColor` and `CALayer.shadowColor` are `CGColor`s — immutable snapshots taken at
    /// assignment time. Unlike a `UIView`'s dynamic `UIColor` properties, UIKit does **not** refresh
    /// them when the user interface style flips between light and dark (a known UIKit gap). A component
    /// that draws a border or shadow on its own layer must therefore re-assign these from the resolved
    /// dynamic `UIColor`'s **current** `.cgColor` whenever `traitCollectionDidChange(_:)` fires.
    ///
    /// Components call `applyDynamicLayerColors(to:border:borderWidth:shadow:)` from their
    /// `traitCollectionDidChange(_:)` (after calling `super`). Passing `nil` for `border` or `shadow`
    /// leaves that aspect untouched / cleared as documented below.
    ///
    /// iOS-only: `CALayer` / `UIColor` belong to UIKit, so this is gated by `#if canImport(UIKit)` and
    /// does not compile under the macOS host (`swift test`).
    enum ThemeableView {
        /// Re-applies the `cgColor`-based border and shadow colors of a layer from resolved dynamic
        /// `UIColor`s.
        ///
        /// Call this from a component's `traitCollectionDidChange(_:)`. The passed `UIColor`s must be
        /// resolved against the owning view's current trait (e.g. by reading them inside the view's
        /// context, or by resolving with `view.traitCollection`), so their `.cgColor` reflects the
        /// active light/dark scheme.
        ///
        /// - Parameters:
        ///   - layer: The layer whose `borderColor` / `shadowColor` should be refreshed.
        ///   - border: The resolved border color, or `nil` to clear the border color.
        ///   - borderWidth: The border width to apply (points). `0` yields no visible border.
        ///   - shadow: The resolved shadow spec, or `nil` to leave the shadow untouched.
        static func applyDynamicLayerColors(
            to layer: CALayer,
            border: UIColor?,
            borderWidth: CGFloat,
            shadow: Appearance.Shadow?
        ) {
            layer.borderWidth = borderWidth
            layer.borderColor = border?.cgColor

            if let shadow {
                layer.shadowColor = shadow.color.cgColor
                layer.shadowOpacity = shadow.opacity
                layer.shadowOffset = shadow.offset
                layer.shadowRadius = shadow.radius
            }
        }
    }
#endif
