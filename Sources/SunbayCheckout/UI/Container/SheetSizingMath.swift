import CoreGraphics

/// Pure sizing arithmetic for the bottom sheet (no UIKit, host-testable); used by `BottomSheetGeometry`.
///
/// Merchant-supplied `Appearance.SheetSizing` values are untrusted input: fractions can be NaN or
/// outside 0...1 and `minHeight` can be NaN, negative, or larger than the sheet can ever be. All of
/// that is sanitized here so the sheet height is always finite and in range.
enum SheetSizingMath {
    /// Fraction used when a supplied fraction is NaN.
    static let fallbackFraction: CGFloat = 0.9

    /// Clamps a fraction to `0...1`; NaN falls back to `fallback`.
    static func clampedFraction(_ value: CGFloat, fallback: CGFloat = fallbackFraction) -> CGFloat {
        guard !value.isNaN else { return fallback }
        return min(max(value, 0), 1)
    }

    /// The target height before clamping: `maxDetent × fixedFraction` when a fixed fraction is
    /// given, otherwise the measured content height (or half the sheet while no measurement exists).
    ///
    /// `.large` mode is handled by `BottomSheetGeometry` (it does not call this), so it needs no
    /// representation here.
    static func targetHeight(
        fixedFraction: CGFloat?, contentHeight: CGFloat, maxDetent: CGFloat
    ) -> CGFloat {
        if let fixedFraction {
            return maxDetent * clampedFraction(fixedFraction, fallback: 0.5)
        }
        return contentHeight > 0 ? contentHeight : maxDetent * 0.5
    }

    /// Clamps `target` into `[minHeight ?? 0, maxDetent × maxFraction]` and never above `maxDetent`.
    ///
    /// - A NaN / negative `minHeight` is treated as no floor.
    /// - If the floor exceeds the fraction cap, the floor wins (but still never exceeds `maxDetent`).
    /// - A NaN `target` resolves to the floor.
    static func clampedHeight(
        target: CGFloat, minHeight: CGFloat?, maxDetent: CGFloat, maxFraction: CGFloat
    ) -> CGFloat {
        let floorHeight: CGFloat
        if let minHeight, !minHeight.isNaN, minHeight > 0 { floorHeight = minHeight } else { floorHeight = 0 }
        let cap = maxDetent * clampedFraction(maxFraction)
        let upper = max(floorHeight, cap)
        let safeTarget = target.isNaN ? floorHeight : target
        return min(min(max(safeTarget, floorHeight), upper), maxDetent)
    }
}
