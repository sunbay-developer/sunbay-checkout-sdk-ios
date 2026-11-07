#if canImport(UIKit)
    import CoreGraphics
    import UIKit

    /// Fully resolved, non-optional appearance values consumed by the UI components (design §4.2).
    ///
    /// The public `Appearance` is a sparse data bag: every color / font field is optional and falls
    /// back to a built-in semantic default. `ResolvedAppearance` collapses that into concrete
    /// `UIColor` / `UIFont` / `CGFloat` values so individual components never read `Appearance` or
    /// re-implement the fallback rules — they receive a `ResolvedAppearance` via init.
    ///
    /// `resolve(_:)` is a pure function (input `Appearance` → output `ResolvedAppearance`, no side
    /// effects, no I/O), which keeps it trivially unit-testable (`ResolvedAppearanceTests`).
    ///
    /// iOS-only: `UIColor` / `UIFont` belong to UIKit, so this is gated by `#if canImport(UIKit)`
    /// and does not compile under the macOS host (`swift test`).
    struct ResolvedAppearance {
        // MARK: - Colors

        /// Brand / accent color.
        let primary: UIColor
        /// Primary surface (screen / sheet) background.
        let background: UIColor
        /// Grouped-component background.
        let componentBackground: UIColor
        /// Primary text color.
        let text: UIColor
        /// Secondary (de-emphasized) text color.
        let textSecondary: UIColor
        /// Hairline border / separator color.
        let border: UIColor
        /// Error / destructive color.
        let danger: UIColor
        /// Success / confirmation color.
        let success: UIColor

        // MARK: - Fonts

        /// Font for card input fields (body text style).
        let cardFieldFont: UIFont
        /// Font for the sheet header title (headline, semibold).
        let titleFont: UIFont
        /// Font for group section headers (caption1, semibold). Smaller than the content, paired
        /// with the primary `text` color + uppercased copy to act as a dark group anchor.
        let sectionHeaderFont: UIFont
        /// Font for section titles (subheadline, semibold).
        let sectionTitleFont: UIFont
        /// Font for checkbox option labels such as "Save this card" (subheadline, regular).
        /// Smaller than the field font so opt-ins sit below the inputs in the visual hierarchy.
        let optionLabelFont: UIFont
        /// Font for the one-line explanation under an option label (footnote, regular).
        let optionHintFont: UIFont
        /// Color for checkbox option labels: the primary text color softened to 70% alpha, so it is
        /// lighter than field content but darker than `textSecondary` placeholders.
        var optionLabelColor: UIColor { text.withAlphaComponent(0.7) }
        /// Font for the primary call-to-action button (headline).
        let ctaFont: UIFont

        // MARK: - Metrics

        /// Corner radius for grouped components, in points.
        let cornerRadius: CGFloat
        /// Border width for grouped components, in points.
        let borderWidth: CGFloat

        // MARK: - Structure

        /// Drop shadow for grouped components.
        let shadow: Appearance.Shadow
        /// Vertical rhythm / spacing density.
        let density: Appearance.Density
        /// Placement of the express-checkout (wallet) row.
        let expressPosition: Appearance.ExpressPosition
        /// Bottom-sheet sizing policy (min height, max fraction, mode).
        let sheetSizing: Appearance.SheetSizing
        /// Whether in-sheet page switches animate.
        let pageTransitionsEnabled: Bool

        // MARK: - Primary button

        /// Primary button background color.
        let primaryButtonBackground: UIColor
        /// Primary button title color.
        let primaryButtonText: UIColor
        /// Primary button corner radius, in points.
        let primaryButtonCornerRadius: CGFloat

        /// Camera card-scanning policy (default `.automatic`; defaulted so other call sites are unchanged).
        var cardScanning: Appearance.CardScanning = .automatic
        // MARK: - Resolution

        /// Resolves a public `Appearance` into concrete, non-optional values.
        ///
        /// Each color uses the merchant override when present, otherwise the matching
        /// `AppearanceDefaults` token. Fonts derive from `appearance.font.base` (or the system
        /// font / preferred text styles) scaled by `appearance.font.sizeScaleFactor`. The primary
        /// button inherits `colors.primary` / white / `appearance.cornerRadius` when its own fields
        /// are nil.
        ///
        /// - Parameter appearance: The public appearance configuration.
        /// - Returns: A fully resolved appearance with no optional fields.
        static func resolve(_ appearance: Appearance) -> ResolvedAppearance {
            let colors = appearance.colors

            let primary = colors.primary ?? AppearanceDefaults.brandPrimary
            let danger = colors.danger ?? AppearanceDefaults.danger
            let success = colors.success ?? AppearanceDefaults.success

            // Fonts: derive each text style from the merchant base font (or the system/preferred
            // font), scaled by sizeScaleFactor. The base font's point size seeds the scaling when a
            // custom font is supplied; otherwise the platform's preferred text styles are used so
            // Dynamic Type still applies.
            let scale = appearance.font.sizeScaleFactor
            let cardFieldFont = Self.font(
                base: appearance.font.base, textStyle: .body, scale: scale, weight: nil)
            let titleFont = Self.font(
                base: appearance.font.base, textStyle: .headline, scale: scale, weight: .semibold)
            let sectionHeaderFont = Self.font(
                base: appearance.font.base, textStyle: .caption1, scale: scale, weight: .semibold)
            let sectionTitleFont = Self.font(
                base: appearance.font.base, textStyle: .subheadline, scale: scale, weight: .semibold)
            let optionLabelFont = Self.font(
                base: appearance.font.base, textStyle: .subheadline, scale: scale, weight: nil)
            let optionHintFont = Self.font(
                base: appearance.font.base, textStyle: .footnote, scale: scale, weight: nil)
            let ctaFont = Self.font(
                base: appearance.font.base, textStyle: .headline, scale: scale, weight: nil)

            let primaryButtonBackground =
                appearance.primaryButton.backgroundColor ?? colors.primary ?? AppearanceDefaults.brandPrimary
            let primaryButtonText = appearance.primaryButton.textColor ?? .white
            let primaryButtonCornerRadius =
                appearance.primaryButton.cornerRadius ?? appearance.cornerRadius

            return ResolvedAppearance(
                primary: primary,
                background: colors.background ?? AppearanceDefaults.background,
                componentBackground: colors.componentBackground ?? AppearanceDefaults.componentBackground,
                text: colors.text ?? AppearanceDefaults.text,
                textSecondary: colors.textSecondary ?? AppearanceDefaults.textSecondary,
                border: colors.border ?? AppearanceDefaults.border,
                danger: danger,
                success: success,
                cardFieldFont: cardFieldFont,
                titleFont: titleFont,
                sectionHeaderFont: sectionHeaderFont,
                sectionTitleFont: sectionTitleFont,
                optionLabelFont: optionLabelFont,
                optionHintFont: optionHintFont,
                ctaFont: ctaFont,
                cornerRadius: appearance.cornerRadius,
                borderWidth: appearance.borderWidth,
                shadow: appearance.shadow,
                density: appearance.density,
                expressPosition: appearance.expressPosition,
                sheetSizing: appearance.sheetSizing,
                pageTransitionsEnabled: appearance.pageTransitionsEnabled,
                primaryButtonBackground: primaryButtonBackground,
                primaryButtonText: primaryButtonText,
                primaryButtonCornerRadius: primaryButtonCornerRadius,
                cardScanning: appearance.cardScanning
            )
        }

        /// Builds a resolved font for a text style.
        ///
        /// When a merchant base font is supplied, its family is reused at the text style's preferred
        /// point size; otherwise the platform preferred font for the style is used (so Dynamic Type
        /// keeps working). An optional weight is applied, and the result is scaled by `scale`.
        private static func font(
            base: UIFont?, textStyle: UIFont.TextStyle, scale: CGFloat, weight: UIFont.Weight?
        ) -> UIFont {
            let preferred = UIFont.preferredFont(forTextStyle: textStyle)
            let basePointSize = preferred.pointSize * scale

            let resolved: UIFont
            if let base {
                // Reuse the merchant font family at this text style's (scaled) size.
                resolved = base.withSize(basePointSize)
            } else if let weight {
                resolved = UIFont.systemFont(ofSize: basePointSize, weight: weight)
            } else {
                resolved = preferred.withSize(basePointSize)
            }

            // Apply weight on top of a custom base font when requested.
            if let base, let weight {
                let descriptor = base.fontDescriptor.addingAttributes([
                    .traits: [UIFontDescriptor.TraitKey.weight: weight]
                ])
                return UIFont(descriptor: descriptor, size: basePointSize)
            }
            return resolved
        }
    }
#endif
