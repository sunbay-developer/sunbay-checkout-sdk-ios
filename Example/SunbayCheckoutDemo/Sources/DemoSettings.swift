import Foundation

// MARK: - Demo settings model

/// The full configuration surface exposed by the demo playground.
///
/// A `Codable`/`Equatable` value type holding every knob the config screen drives. It maps to a
/// `CheckoutConfiguration` (always the `.dev` environment) plus the dev-session request at Pay time.
/// Deliberately a plain value type (no SDK reference types) so SwiftUI can diff it and so it stays
/// trivially serializable.
struct DemoSettings: Codable, Equatable {
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

    /// An appearance preset mirroring the prototype's "Customize" lab.
    ///
    /// Each case maps to a concrete `Appearance` (primary color, corner radius, express position,
    /// density, color scheme). The raw value is a stable identifier for SwiftUI/Codable; the
    /// `Appearance` itself is UIKit-only and built in `DemoRootView` (this value type stays free of
    /// SDK reference/UIKit types so it remains trivially `Codable`/`Equatable`).
    enum DemoAppearancePreset: String, Codable, CaseIterable, Identifiable {
        /// Brand default: orange #ff6000, rounded corners, express on top.
        case brandDefault
        /// Sharp corners, blue #2563eb primary, express at the bottom, compact density.
        case sharpBlueExpressBottom
        /// Round corners, green #16a34a primary, forced dark scheme.
        case roundGreenDark

        var id: String { rawValue }

        /// A short display label.
        var label: String {
            switch self {
            case .brandDefault: return "Default (orange)"
            case .sharpBlueExpressBottom: return "Sharp · Blue · Express bottom"
            case .roundGreenDark: return "Round · Green · Dark"
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
    /// The color-scheme override (maps to `Appearance.colorScheme`).
    var colorScheme: DemoColorScheme
    /// The billing address collection mode (maps to `Appearance.billingAddressMode`).
    var billingAddressMode: DemoAddressMode
    /// The shipping address collection mode (maps to `Appearance.shippingAddressMode`).
    var shippingAddressMode: DemoAddressMode
    /// Ask the dev server to create sessions with `collectBillingAddress` on.
    var orderRequiresBillingAddress: Bool = false
    /// Ask the dev server to create sessions with `collectShippingAddress` on.
    var orderRequiresShippingAddress: Bool = false
    /// Pass a fixed US test billing address to `PaymentSheet(billingAddress:)`.
    var passHostBillingAddress: Bool = false
    /// Pass a fixed, complete US test shipping address (with names and phone) to `PaymentSheet(shippingAddress:)`.
    var passHostShippingAddress: Bool = false
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
