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

    // MARK: Apple Pay button color

    /// The Apple Pay button color (maps to `Appearance.applePayButtonStyle` and `ExpressCheckoutElement.Configuration.buttonStyle`).
    enum DemoApplePayStyle: String, Codable, CaseIterable, Identifiable {
        case automatic, black, white

        var id: String { rawValue }

        /// A short display label.
        var label: String {
            switch self {
            case .automatic: return "Automatic"
            case .black: return "Black"
            case .white: return "White"
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

    /// Address form style. Maps to `Appearance.AddressFormStyle`.
    enum DemoAddressStyle: String, Codable, CaseIterable, Identifiable {
        case simple
        case full

        var id: String { rawValue }

        /// A short display label.
        var label: String {
            switch self {
            case .simple: return "Simple (country / line1 / ZIP)"
            case .full: return "Full (backend layout)"
            }
        }
    }

    // MARK: Stored knobs

    /// Backend environment (SDK `CheckoutConfiguration.environment` and the dev server's credentials). Default dev.
    var environment: DemoEnvironment = .dev

    /// Locale (drives SDK PaymentSheet localization).
    var locale: DemoLocale
    /// The order amount in USD (major units, for example `1.05`), as typed.
    var amount: String
    /// The order tax in USD (major units), entered by hand. Default `0`.
    var tax: String = "0"

    /// Keeps a money entry to digits with at most one `.` and two decimals (`"1.234"` -> `"1.23"`).
    static func sanitizeMoney(_ text: String) -> String {
        var result = ""
        var decimals: Int?
        for character in text {
            if character.isASCII, character.isNumber {
                if let count = decimals {
                    guard count < 2 else { continue }
                    decimals = count + 1
                }
                result.append(character)
            } else if character == "." || character == ",", decimals == nil {
                result.append(result.isEmpty ? "0." : ".")
                decimals = 0
            }
        }
        return result
    }

    /// A money entry in major units; empty or malformed text counts as `0`.
    static func majorUnits(_ text: String) -> Double { Double(text) ?? 0 }
    /// Disable card on file (maps to `!CardOnFileOptions.isEnabled`). Off by default: follow the session.
    var disableCardOnFile: Bool = false
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
    /// Disable the billing form (maps to `!Appearance.billingAddressEnabled`). Off by default: follow the session.
    var disableBillingAddress: Bool = false
    /// Disable the shipping form (maps to `!Appearance.shippingAddressEnabled`). Off by default: follow the session.
    var disableShippingAddress: Bool = false
    /// The billing form style (maps to `Appearance.billingAddressStyle`).
    var billingAddressStyle: DemoAddressStyle = .simple
    /// The shipping form style (maps to `Appearance.shippingAddressStyle`).
    var shippingAddressStyle: DemoAddressStyle = .simple
    /// Ask the dev server to create sessions with `collectBillingAddress` on.
    var orderRequiresBillingAddress: Bool = true
    /// Ask the dev server to create sessions with `collectShippingAddress` on.
    var orderRequiresShippingAddress: Bool = false
    /// Ask the dev server to create sessions that allow saved cards (the session's card-on-file flag).
    var orderSupportsSavedCards: Bool = true
    /// The user identifier (session `customerId`) saved cards belong to; sent only when saved cards are on.
    var customerId: String = "example-user@sunbay.us"
    /// Pass a fixed US test billing address to `PaymentSheet(billingAddress:)`.
    var passHostBillingAddress: Bool = false
    /// Pass a fixed, complete US test shipping address (with names and phone) to `PaymentSheet(shippingAddress:)`.
    var passHostShippingAddress: Bool = false
    /// The wording on the Apple Pay button, in the sheet's express row and the embedded button.
    var applePayText: DemoApplePayText = .plain
    /// The Apple Pay button color, in the sheet's express row and the embedded button.
    var applePayStyle: DemoApplePayStyle = .automatic
    /// Hide Apple Pay through `PaymentMethodFilter(hide:)`.
    var hideApplePay: Bool = false
    /// Hide the card methods (new card and saved cards) through `PaymentMethodFilter(hide:)`.
    var hideCard: Bool = false
    /// Base URL of the local dev session server.
    var devServerURL: String = "http://127.0.0.1:8095"

    /// Default settings: 1 USD, COF on, automatic addresses, brand appearance.
    static let `default` = DemoSettings(
        locale: .enUS,
        amount: "1",
        appearancePreset: .brandDefault,
        colorScheme: .automatic,
    )
}
