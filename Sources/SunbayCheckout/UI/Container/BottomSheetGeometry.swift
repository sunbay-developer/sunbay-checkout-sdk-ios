import CoreGraphics

/// Pure geometry for the custom iPhone bottom sheet (no UIKit, host-testable).
///
/// The presentation layer feeds in measurements (container height, top safe-area inset, keyboard
/// overlap, the content's reported total height) and gets back the explicit sheet height. All the
/// sanitizing of merchant-supplied sizing lives in `SheetSizingMath`; this type only decides which
/// reference height each policy value applies to:
///
/// - **Available height** = container height − top safe-area inset − keyboard overlap. A sheet is
///   never taller than this, so it never slides under the status bar / Dynamic Island or the keyboard.
/// - `maxHeightFraction` is a hard cap expressed against the **container** height (the screen),
///   additionally bounded by the available height.
/// - `.fixedFraction(f)` is `f ×` container height. `.adaptive` is the content height.
/// - `.large` is the full available height (it intentionally bypasses `maxHeightFraction`).
enum BottomSheetGeometry {
    /// The sizing policy in primitive form (mirrors `Appearance.SheetSizing` without UIKit).
    struct Policy: Equatable {
        enum Mode: Equatable {
            case adaptive
            case fixedFraction(CGFloat)
            case large
        }

        var minHeight: CGFloat?
        var maxHeightFraction: CGFloat
        var mode: Mode

        init(minHeight: CGFloat? = nil, maxHeightFraction: CGFloat = 0.9, mode: Mode = .adaptive) {
            self.minHeight = minHeight
            self.maxHeightFraction = maxHeightFraction
            self.mode = mode
        }
    }

    /// Fraction of the available height used as the sheet height until the content reports one.
    static let initialFraction: CGFloat = 0.5

    /// Top-corner radius of the sheet: design token `--sr` = `max(cornerRadius + 12, 14)`.
    static func cornerRadius(appearanceCornerRadius: CGFloat) -> CGFloat {
        let base = appearanceCornerRadius.isFinite ? appearanceCornerRadius : 0
        return max(base + 12, 14)
    }

    /// Height the sheet may occupy: container minus top safe area minus keyboard. Never negative / NaN.
    static func availableHeight(
        containerHeight: CGFloat, safeAreaTop: CGFloat, keyboardOverlap: CGFloat
    ) -> CGFloat {
        let value = sanitized(containerHeight) - sanitized(safeAreaTop) - sanitized(keyboardOverlap)
        return max(0, value)
    }

    /// How far the keyboard covers the container's bottom edge (0 when hidden or not overlapping).
    ///
    /// Both rects must be in the same coordinate space (the container's).
    static func keyboardOverlap(containerBounds: CGRect, keyboardFrame: CGRect) -> CGFloat {
        guard !keyboardFrame.isNull, !keyboardFrame.isEmpty,
            keyboardFrame.minY.isFinite, containerBounds.maxY.isFinite
        else { return 0 }
        return min(max(0, containerBounds.maxY - keyboardFrame.minY), max(0, containerBounds.height))
    }

    /// The explicit sheet height for the given measurements and policy.
    ///
    /// - Parameter contentHeight: the content's reported total height; `<= 0` / NaN means "not
    ///   measured yet" and yields `initialFraction × available` for `.adaptive`.
    static func sheetHeight(
        containerHeight: CGFloat,
        safeAreaTop: CGFloat,
        keyboardOverlap: CGFloat,
        contentHeight: CGFloat,
        policy: Policy
    ) -> CGFloat {
        let container = sanitized(containerHeight)
        let available = availableHeight(
            containerHeight: container, safeAreaTop: safeAreaTop, keyboardOverlap: keyboardOverlap)
        guard available > 0 else { return 0 }

        let fixedFraction: CGFloat?
        switch policy.mode {
        case .large:
            return available
        case let .fixedFraction(fraction):
            fixedFraction = fraction
        case .adaptive:
            fixedFraction = nil
        }

        // Fixed fractions apply to the container height; adaptive falls back to a share of what is
        // available until the content has been measured.
        let content = contentHeight.isFinite && contentHeight > 0 ? contentHeight : 0
        let target: CGFloat
        if fixedFraction != nil {
            target = SheetSizingMath.targetHeight(
                fixedFraction: fixedFraction, contentHeight: content, maxDetent: container)
        } else {
            target = content > 0 ? content : available * initialFraction
        }

        // `maxHeightFraction` is relative to the container; `SheetSizingMath` caps relative to
        // `maxDetent` (= available), so convert the fraction. The result is still ≤ available.
        let fraction = SheetSizingMath.clampedFraction(policy.maxHeightFraction)
        let capFraction = min(1, container * fraction / available)
        return SheetSizingMath.clampedHeight(
            target: target, minHeight: policy.minHeight, maxDetent: available, maxFraction: capFraction)
    }

    private static func sanitized(_ value: CGFloat) -> CGFloat {
        value.isFinite ? max(0, value) : 0
    }
}
