#if canImport(UIKit)
    import CoreGraphics
    import UIKit

    /// Appearance configuration for the checkout UI (Stripe-style nested value type, design §4.1).
    ///
    /// This type is part of the public API. It is a plain data bag describing how the SDK UI should
    /// look; the Theme layer turns it into concrete, non-optional values via `ResolvedAppearance`.
    /// Every field is optional or has a default, so a merchant overrides only what they care about
    /// (Stripe style: default-init, then set properties).
    ///
    /// iOS-only: the nested types carry `UIColor` / `UIFont`, which belong to UIKit, so the whole
    /// type is gated by `#if canImport(UIKit)` and does not compile under the macOS host
    /// (`swift test`). `CheckoutConfiguration.appearance` is `#if`-wrapped accordingly; Core never
    /// consumes appearance.
    public struct Appearance: Sendable, Equatable {
        /// The default appearance (all built-in semantic defaults).
        public static let `default` = Appearance()

        /// Creates an appearance with all built-in defaults. Set individual properties to override.
        public init() {}

        /// Color overrides. Each `nil` field falls back to the built-in semantic default.
        public var colors: Colors = .init()
        /// Font override (base font + size scale factor).
        public var font: Font = .init()
        /// Primary call-to-action button overrides.
        public var primaryButton: PrimaryButton = .init()
        /// Corner radius for grouped components, in points.
        public var cornerRadius: CGFloat = 10
        /// Border width for grouped components, in points. `0` yields a borderless (hairline) look.
        public var borderWidth: CGFloat = 1
        /// Drop shadow applied to grouped components.
        public var shadow: Shadow = .none
        /// Color scheme preference; drives `overrideUserInterfaceStyle`.
        public var colorScheme: ColorScheme = .automatic
        /// Vertical rhythm / spacing density.
        public var density: Density = .comfortable
        /// Where the express-checkout (wallet) row is placed on the home page (top / bottom / off).
        public var expressPosition: ExpressPosition = .top
        /// The wording on the Apple Pay button in the express row (default `.plain`, the logo only).
        public var applePayButtonType: ApplePayButtonType = .plain
        /// The color of the Apple Pay button in the express row. Defaults to `.automatic`: it follows the
        /// sheet's light/dark appearance (``colorScheme``).
        public var applePayButtonStyle: ApplePayButtonStyle = .automatic
        /// Whether the billing address form may be shown. Defaults to `true`: whether it is actually
        /// shown follows the checkout session's `collectBillingAddress` flag. Set `false` to never show
        /// it; a billing address the host passes in is still sent. The host cannot force the form on
        /// when the session does not ask for it.
        public var billingAddressEnabled: Bool = true
        /// Whether the shipping address form may be shown. Same rules as ``billingAddressEnabled``,
        /// following the session's `collectShippingAddress` flag.
        public var shippingAddressEnabled: Bool = true
        /// How the billing address form looks when it is shown. Defaults to `.simple`.
        public var billingAddressStyle: AddressFormStyle = .simple
        /// How the shipping address form looks when it is shown. Defaults to `.simple`.
        public var shippingAddressStyle: AddressFormStyle = .simple

        /// Whether the "Scan card" button is offered on the new-card page. Defaults to `.automatic`.
        public var cardScanning: CardScanning = .automatic

        /// Bottom-sheet sizing: minimum height, maximum height fraction of the screen height, and mode.
        public var sheetSizing: SheetSizing = .init()

        /// Whether page switches inside the sheet (e.g. home ↔ new-card) animate with a
        /// forward/backward slide. Defaults to `true`. The system "Reduce Motion" setting always
        /// downgrades the slide to a cross-fade.
        public var pageTransitionsEnabled: Bool = true

        /// Color scheme preference.
        public enum ColorScheme: Sendable {
            /// Force light.
            case light
            /// Force dark.
            case dark
            /// Follow the system.
            case automatic
        }

        /// Vertical rhythm / spacing density.
        public enum Density: Sendable {
            /// Roomy spacing (default).
            case comfortable
            /// Tighter spacing.
            case compact
        }

        /// Placement of the express-checkout (wallet) row on the home page. The express row never
        /// appears on the new-card subpage.
        public enum ExpressPosition: Sendable {
            /// First on the home page, above the saved cards and the "New card" entry.
            case top
            /// Last on the home page, below the saved cards and the "New card" entry.
            case bottom
            /// Hidden.
            case off
        }

        /// Camera card scanning policy. Scanning is fully on-device (no network).
        public enum CardScanning: Sendable {
            /// Show "Scan card" only when it can work: the host app declares
            /// `NSCameraUsageDescription` in its Info.plist, a camera exists, and camera access is not
            /// denied or restricted. This is the default.
            case automatic
            /// Never show "Scan card".
            case disabled
        }

        /// The color of the sheet's Apple Pay button (Apple's official button styles).
        public enum ApplePayButtonStyle: Sendable {
            /// Follows the sheet's appearance: black on a light sheet, white on a dark sheet.
            case automatic
            /// Always black with white text.
            case black
            /// Always white with black text and a thin outline, so it stays visible on a light sheet.
            case white
        }

        /// How an address form looks, independent of whether it is shown.
        public enum AddressFormStyle: Sendable {
            /// Three fields: country / line1 / postal code (plus first/last name for shipping).
            case simple
            /// Backend-layout-driven full address form.
            case full
        }

        /// Bottom-sheet sizing policy.
        ///
        /// `mode` chooses the sheet's height, which is then clamped between `minHeight` and
        /// `screenHeight × maxHeightFraction`. "Screen height" is the height of the presentation
        /// container (the full window); the sheet can never exceed the *available* height, i.e. the
        /// screen height minus the top safe-area inset minus any keyboard overlap:
        /// - `.adaptive` (default): the height fits the content, so a short form yields a short sheet
        ///   and a long form grows up to the cap (the middle area then scrolls).
        /// - `.fixedFraction(f)`: the height is `screenHeight × f` (`f` clamped to `0...1`, then by
        ///   `minHeight` and `maxHeightFraction`).
        /// - `.large`: fills the whole available height. Bypasses `maxHeightFraction` by design.
        ///
        /// This sizing applies to the custom iPhone bottom sheet on **all** supported iOS versions
        /// (15+). `maxHeightFraction` is a **hard cap**: the sheet never grows past it, and there is
        /// no pull-up gesture or system large detent. Out-of-range inputs are sanitized (fractions
        /// clamped to `0...1`, a NaN or negative `minHeight` is ignored; if `minHeight` exceeds the
        /// cap it wins, but never exceeds the available height). The height is re-evaluated when the
        /// content changes, on rotation, and when the keyboard shows or hides.
        ///
        /// iPad, Mac (Catalyst) and visionOS present the sheet as a system form sheet instead (Stripe
        /// parity); the system sizes that sheet, so `sheetSizing` does **not** apply there.
        public struct SheetSizing: Sendable, Equatable {
            /// Sizing mode.
            public enum Mode: Sendable, Equatable {
                /// Fit the content height, clamped to `[minHeight, screenHeight × maxHeightFraction]`.
                case adaptive
                /// Always `screenHeight × fraction` (clamped by `minHeight` / `maxHeightFraction`).
                case fixedFraction(CGFloat)
                /// Fill the whole available height (screen minus top safe area minus keyboard).
                case large
            }

            /// Minimum sheet height in points. `nil` lets the content fit without a floor.
            public var minHeight: CGFloat?
            /// Hard cap on the sheet height as a fraction of the screen height (0...1). Default `0.9`.
            public var maxHeightFraction: CGFloat
            /// How the target height is derived. Default `.adaptive`.
            public var mode: Mode

            /// Creates a sizing policy.
            ///
            /// - Parameters:
            ///   - minHeight: Minimum height in points; `nil` for no floor.
            ///   - maxHeightFraction: Hard cap as a fraction of the screen height (default `0.9`).
            ///   - mode: Sizing mode (default `.adaptive`).
            public init(
                minHeight: CGFloat? = nil,
                maxHeightFraction: CGFloat = 0.9,
                mode: Mode = .adaptive
            ) {
                self.minHeight = minHeight
                self.maxHeightFraction = maxHeightFraction
                self.mode = mode
            }
        }

        /// Color overrides. A `nil` value falls back to the built-in semantic default.
        public struct Colors: Sendable, Equatable {
            /// Creates an all-default color set.
            public init() {}

            /// Brand / accent color. `nil` → built-in brand.
            public var primary: UIColor?
            /// Primary surface (screen / sheet) background. `nil` → semantic background.
            public var background: UIColor?
            /// Grouped-component background. `nil` → semantic component background.
            public var componentBackground: UIColor?
            /// Primary text color. `nil` → semantic text.
            public var text: UIColor?
            /// Secondary (de-emphasized) text color. `nil` → semantic secondary text.
            public var textSecondary: UIColor?
            /// Hairline border / separator color. `nil` → semantic border.
            public var border: UIColor?
            /// Error / destructive color. `nil` → built-in danger.
            public var danger: UIColor?
            /// Success / confirmation color. `nil` → built-in success.
            public var success: UIColor?
        }

        /// Font override.
        public struct Font: Sendable, Equatable {
            /// Creates an all-default font set.
            public init() {}

            /// Base font. `nil` → system font. Resolved fonts derive their sizes from this.
            public var base: UIFont?
            /// Multiplier applied to every resolved text-style point size.
            public var sizeScaleFactor: CGFloat = 1.0
        }

        /// Primary call-to-action button overrides.
        public struct PrimaryButton: Sendable, Equatable {
            /// Creates an all-default primary-button config.
            public init() {}

            /// Button background color. `nil` → `colors.primary`.
            public var backgroundColor: UIColor?
            /// Button title color. `nil` → white (contrast-checked).
            public var textColor: UIColor?
            /// Button corner radius. `nil` → inherits `Appearance.cornerRadius`.
            public var cornerRadius: CGFloat?
        }

        /// Drop shadow for grouped components.
        public struct Shadow: Sendable, Equatable {
            /// Shadow color.
            public let color: UIColor
            /// Shadow opacity.
            public let opacity: Float
            /// Shadow offset.
            public let offset: CGSize
            /// Shadow blur radius.
            public let radius: CGFloat

            /// Creates a shadow.
            ///
            /// - Parameters:
            ///   - color: Shadow color.
            ///   - opacity: Shadow opacity.
            ///   - offset: Shadow offset.
            ///   - radius: Shadow blur radius.
            public init(color: UIColor, opacity: Float, offset: CGSize, radius: CGFloat) {
                self.color = color
                self.opacity = opacity
                self.offset = offset
                self.radius = radius
            }

            /// No shadow.
            public static let none = Shadow(color: .clear, opacity: 0, offset: .zero, radius: 0)
            /// A subtle shadow.
            public static let soft = Shadow(
                color: .black, opacity: 0.08, offset: .init(width: 0, height: 1), radius: 2)
            /// A stronger shadow.
            public static let medium = Shadow(
                color: .black, opacity: 0.14, offset: .init(width: 0, height: 3), radius: 10)
        }
    }
#endif
