import Foundation

// MARK: - Demo settings model

/// The full configuration surface exposed by the demo playground.
///
/// A `Codable`/`Equatable` value type holding every knob the config screen drives. It maps to a
/// `CheckoutConfiguration` (dev by default; the environment is switchable) plus the dev-session request at Pay time.
/// Deliberately a plain value type (no SDK reference types) so SwiftUI can diff it and so it stays
/// trivially serializable.
struct DemoSettings: Codable, Equatable {
    // MARK: Environment

    /// The backend environment the SDK talks to and the dev server creates sessions for.
    enum DemoEnvironment: String, Codable, CaseIterable, Identifiable {
        case dev
        case test
        case prod

        var id: String { rawValue }

        /// The name the dev server expects in `environment`.
        var serverName: String { rawValue }

        /// A short display label.
        var label: String {
            switch self {
            case .dev: return "Dev"
            case .test: return "Test"
            case .prod: return "Prod"
            }
        }
    }

    // MARK: Locale

    /// Locale knob. The raw value is a BCP-47 code passed straight into
    /// `CheckoutConfiguration.locale`, which drives SDK PaymentSheet localization at runtime
    /// (switch to `zh-CN` to see the SDK render its Chinese strings).
    enum DemoLocale: String, Codable, CaseIterable, Identifiable {
        case enUS = "en-US"
        case zhCN = "zh-CN"

        var id: String { rawValue }

        /// The BCP-47 code handed to `CheckoutConfiguration.locale`.
        var bcp47: String { rawValue }

        /// A short display label (ASCII only; the SDK itself renders the localized UI strings).
        var label: String {
            switch self {
            case .enUS: return "English (en-US)"
            case .zhCN: return "Chinese (zh-CN)"
            }
        }
    }

    // MARK: Appearance preset

    /// A theme preset.
    ///
    /// Each case maps to a concrete `Appearance` (colors, corner radius, shadow, density, express
    /// position, color scheme) built in `DemoRootView`; this value type stays free of UIKit types so it
    /// remains trivially `Codable`/`Equatable`.
    enum DemoAppearancePreset: String, Codable, CaseIterable, Identifiable {
        /// Brand default: orange #ff6000, rounded corners, express on top.
        case brandDefault
        /// Sharp corners, blue #2563eb primary, express at the bottom, compact density.
        case sharpBlueExpressBottom
        /// Round corners, green #16a34a primary, forced dark scheme.
        case roundGreenDark
        /// Dark navy surfaces with a violet accent and a medium shadow.
        case midnight
        /// Light blue surfaces with a soft shadow.
        case ocean
        /// Warm rose accent with pill-shaped controls and a medium shadow.
        case sunset
        /// Black on white, square corners, thick borders, compact.
        case mono
        /// Cream paper, brown accent, serif font.
        case editorial

        var id: String { rawValue }

        /// A short display label.
        var label: String {
            switch self {
            case .brandDefault: return "Default"
            case .sharpBlueExpressBottom: return "Sharp Blue"
            case .roundGreenDark: return "Round Green"
            case .midnight: return "Midnight"
            case .ocean: return "Ocean"
            case .sunset: return "Sunset"
            case .mono: return "Mono"
            case .editorial: return "Editorial"
            }
        }

        /// A one-line description of what the theme changes.
        var detail: String {
            switch self {
            case .brandDefault: return "Orange, rounded, express on top"
            case .sharpBlueExpressBottom: return "Sharp corners, compact, express at the bottom"
            case .roundGreenDark: return "Round corners, forced dark"
            case .midnight: return "Dark navy, violet accent, medium shadow"
            case .ocean: return "Light blue surfaces, soft shadow"
            case .sunset: return "Rose accent, pill-shaped controls"
            case .mono: return "Black and white, square, thick borders"
            case .editorial: return "Cream paper, brown accent, serif font"
            }
        }

        /// The accent color shown as the swatch in the theme list.
        var swatchHex: String {
            switch self {
            case .brandDefault: return "#ff6000"
            case .sharpBlueExpressBottom: return "#2563eb"
            case .roundGreenDark: return "#16a34a"
            case .midnight: return "#8b5cf6"
            case .ocean: return "#0ea5e9"
            case .sunset: return "#f43f5e"
            case .mono: return "#111827"
            case .editorial: return "#92400e"
            }
        }
    }

    // MARK: Apple Pay button wording

    /// The wording on the Apple Pay button (maps to `ApplePayButtonType`).
    enum DemoApplePayText: String, Codable, CaseIterable, Identifiable {
        case plain, buy, setUp, inStore, donate, checkout, book, subscribe
        case reload, addMoney, topUp, order, rent, support, contribute, tip

        var id: String { rawValue }

        /// A short display label.
        var label: String {
            switch self {
            case .plain: return "Plain (logo only)"
            case .buy: return "Buy"
            case .setUp: return "Set up"
            case .inStore: return "In store"
            case .donate: return "Donate"
            case .checkout: return "Check out"
            case .book: return "Book"
            case .subscribe: return "Subscribe"
            case .reload: return "Reload"
            case .addMoney: return "Add money"
            case .topUp: return "Top up"
            case .order: return "Order"
            case .rent: return "Rent"
            case .support: return "Support"
            case .contribute: return "Contribute"
            case .tip: return "Tip"
            }
        }
    }

    // MARK: Effects

    /// Shadow override (maps to `Appearance.shadow`); `theme` keeps the theme's own value.
    enum DemoShadow: String, Codable, CaseIterable, Identifiable {
        case theme, none, soft, medium

        var id: String { rawValue }

        var label: String {
            switch self {
            case .theme: return "Theme"
            case .none: return "None"
            case .soft: return "Soft"
            case .medium: return "Medium"
            }
        }
    }

    /// Sheet size override (maps to `Appearance.sheetSizing`).
    enum DemoSheetSize: String, Codable, CaseIterable, Identifiable {
        case adaptive, half, large

        var id: String { rawValue }

        var label: String {
            switch self {
            case .adaptive: return "Adaptive"
            case .half: return "Half"
            case .large: return "Large"
            }
        }
    }

    // MARK: Color scheme

    /// Color-scheme knob. Maps to `Appearance.ColorScheme` (drives `overrideUserInterfaceStyle`).
    ///
    /// When a preset forces a scheme (e.g. "Round · Green · Dark"), this knob takes precedence only
    /// when the user changes it away from `automatic`; see `DemoRootView.makeAppearance`.
    enum DemoColorScheme: String, Codable, CaseIterable, Identifiable {
        case automatic
        case light
        case dark

        var id: String { rawValue }

        /// A short display label.
        var label: String {
            switch self {
            case .automatic: return "Automatic"
            case .light: return "Light"
            case .dark: return "Dark"
            }
        }
    }

    // MARK: Address collection mode

    /// Billing/shipping address-collection knob. Maps to `Appearance.AddressCollectionMode`.
    ///
    /// `.automatic` follows the session's `collectXAddress` flag (flag on: full form, off: hidden).
    /// `.simple` / `.full` / `.off` are explicit host choices that ignore the flag. The session flags
    /// themselves are driven by the separate "Order requires ..." toggles.
    enum DemoAddressMode: String, Codable, CaseIterable, Identifiable {
        case automatic
        case simple
        case full
        case off

        var id: String { rawValue }

        /// A short display label.
        var label: String {
            switch self {
            case .automatic: return "Automatic (follow session)"
            case .simple: return "Simple (country / line1 / ZIP)"
            case .full: return "Full (backend layout)"
            case .off: return "Off (not collected)"
            }
        }
    }

    // MARK: Stored knobs

    /// Backend environment (SDK `CheckoutConfiguration.environment` and the dev server's credentials). Default dev.
    var environment: DemoEnvironment = .dev

    /// Locale (drives SDK PaymentSheet localization).
    var locale: DemoLocale
    /// The order amount in minor units of USD (for example cents). Sent to the dev server as major units.
    var amountMinorUnits: Int64
    /// Host-side card-on-file switch (maps to `CardOnFileOptions.isEnabled`). Default on.
    var cardOnFileEnabled: Bool = true
    /// Pre-tick the "save card" checkbox (maps to `CardOnFileOptions.saveByDefault`). Default off.
    var preTickSaveCard: Bool = false
    /// The appearance preset (maps to an `Appearance` at Pay time).
    var appearancePreset: DemoAppearancePreset
    /// The shadow override (maps to `Appearance.shadow`).
    var shadow: DemoShadow = .theme
    /// The sheet size override (maps to `Appearance.sheetSizing`).
    var sheetSize: DemoSheetSize = .adaptive
    /// Whether page transitions animate (maps to `Appearance.pageTransitionsEnabled`).
    var pageTransitions: Bool = true
    /// The color-scheme override (maps to `Appearance.colorScheme`).
    var colorScheme: DemoColorScheme
    /// The billing address collection mode (maps to `Appearance.billingAddressMode`).
    var billingAddressMode: DemoAddressMode
    /// The shipping address collection mode (maps to `Appearance.shippingAddressMode`).
    var shippingAddressMode: DemoAddressMode
    /// Ask the dev server to create sessions with `collectBillingAddress` on.
    var orderRequiresBillingAddress: Bool = true
    /// Ask the dev server to create sessions with `collectShippingAddress` on.
    var orderRequiresShippingAddress: Bool = false
    /// Ask the dev server to create sessions that allow saved cards (the session's card-on-file flag).
    var orderSupportsSavedCards: Bool = true
    /// Pass a fixed US test billing address to `PaymentSheet(billingAddress:)`.
    var passHostBillingAddress: Bool = false
    /// Pass a fixed, complete US test shipping address (with names and phone) to `PaymentSheet(shippingAddress:)`.
    var passHostShippingAddress: Bool = false
    /// The wording on the Apple Pay button, in the sheet's express row and the embedded button.
    var applePayText: DemoApplePayText = .plain
    /// Hide Apple Pay through `PaymentMethodFilter(hide:)`.
    var hideApplePay: Bool = false
    /// Hide the card methods (new card and saved cards) through `PaymentMethodFilter(hide:)`.
    var hideCard: Bool = false
    /// Base URL of the local dev session server.
    var devServerURL: String = "http://127.0.0.1:8095"

    /// Default settings: 1.05 USD, COF on, automatic addresses, brand appearance.
    static let `default` = DemoSettings(
        locale: .enUS,
        amountMinorUnits: 105,
        appearancePreset: .brandDefault,
        colorScheme: .automatic,
        billingAddressMode: .automatic,
        shippingAddressMode: .automatic
    )
}
