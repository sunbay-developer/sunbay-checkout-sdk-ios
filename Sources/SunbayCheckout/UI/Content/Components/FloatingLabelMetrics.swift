#if canImport(UIKit)
    import UIKit

    /// Shared design tokens for the floating-label controls (`FloatingLabelTextField` /
    /// `FloatingLabelMenuField`), so the band height, label shrink ratio, and minimum floated size are
    /// defined once rather than duplicated (and drifting) across both components.
    enum FloatingLabelMetrics {
        /// The top band reserved for the floated (raised, shrunk) label, in points.
        static let floatBand: CGFloat = 18

        /// The fraction the resting font is shrunk to when the label floats.
        static let floatedShrink: CGFloat = 0.72

        /// The smallest floated label size, so the label stays legible at small base fonts / Dynamic Type.
        static let minFloatedPointSize: CGFloat = 11

        /// Derives the floated (small) label font from the resting font, preserving the font family so a
        /// merchant base font still applies.
        ///
        /// - Parameter restingFont: The field's resting font (the resolved `cardFieldFont`).
        /// - Returns: The shrunk font used for the floated label.
        static func floatedFont(from restingFont: UIFont) -> UIFont {
            restingFont.withSize(max(minFloatedPointSize, restingFont.pointSize * floatedShrink))
        }
    }
#endif
