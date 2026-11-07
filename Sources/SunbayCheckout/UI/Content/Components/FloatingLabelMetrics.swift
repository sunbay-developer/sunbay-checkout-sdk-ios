#if canImport(UIKit)
    import UIKit

    /// Shared design tokens for the floating-label controls (`FloatingLabelTextField` /
    /// `FloatingLabelMenuField`), so the band height, label shrink ratio, and minimum floated size are
    /// defined once rather than duplicated (and drifting) across both components.
    enum FloatingLabelMetrics {
        /// The top band reserved for the floated (raised, shrunk) label, in points.
        static let floatBand: CGFloat = 24

        /// Space between the field's top edge and the floated label's top, in points.
        static let floatedLabelTopInset: CGFloat = 9

        /// Space between the value text and the field's bottom edge, in points.
        static let bottomInset: CGFloat = 8

        /// Minimum height of a floating-label field box, in points.
        static let minFieldHeight: CGFloat = 60

        /// Scale applied to the theme field font so the input text is compact (Stripe-like ~16pt).
        static let fieldFontScale: CGFloat = 0.94

        /// The field's input / resting-label font, derived from the theme field font.
        static func fieldFont(from themeFont: UIFont) -> UIFont {
            themeFont.withSize((themeFont.pointSize * fieldFontScale).rounded())
        }

        /// The fraction the resting font is shrunk to when the label floats.
        static let floatedShrink: CGFloat = 0.78

        /// The smallest floated label size, so the label stays legible at small base fonts / Dynamic Type.
        static let minFloatedPointSize: CGFloat = 12

        /// Derives the floated (small) label font from the resting font, preserving the font family so a
        /// merchant base font still applies.
        ///
        /// - Parameter restingFont: The field's resting font (the resolved `cardFieldFont`).
        /// - Returns: The shrunk font used for the floated label.
        static func floatedFont(from restingFont: UIFont) -> UIFont {
            restingFont.withSize(max(minFloatedPointSize, (restingFont.pointSize * floatedShrink).rounded()))
        }
    }
#endif
