import Foundation
import SunbayCheckout

// MARK: - Demo settings model

/// The full configuration surface exposed by the demo playground.
///
/// A `Codable`/`Equatable` value type holding every knob the config screen drives. It maps to a
/// `CheckoutConfiguration` plus the scripted mock services (from `SunbayCheckoutTestSupport`) at Pay time.
/// Deliberately a plain value type (no SDK reference types) so SwiftUI can diff it and so it stays
/// trivially serializable.
struct DemoSettings: Codable, Equatable {
    // MARK: Runtime environment

    /// Runtime environment knob. Maps to `CheckoutConfiguration.Environment`.
    enum DemoEnvironment: String, Codable, CaseIterable, Identifiable {
        case dev
        case test
        case production

        var id: String { rawValue }

        /// The SDK configuration value for this knob.
        var configurationValue: CheckoutConfiguration.Environment {
            switch self {
            case .dev: return .dev
            case .test: return .test
            case .production: return .production
            }
        }

        /// A short display label.
        var label: String {
            switch self {
            case .dev: return "Dev"
            case .test: return "Test"
            case .production: return "Production"
            }
        }
    }

    // MARK: Backend mode

    /// Where sessions and payments come from. `mock` (default) uses scripted doubles. `realDevServer`
    /// is DEBUG-only: a local dev server creates the session and the SDK talks to the real backend.
    enum DemoMode: String, Codable, CaseIterable, Identifiable {
        case mock
        case realDevServer

        var id: String { rawValue }

        /// A short display label.
        var label: String {
            switch self {
            case .mock: return "Mock"
            case .realDevServer: return "Real (dev server)"
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

    // MARK: Payment methods

    /// A payment-method toggle in the playground. Maps to `PaymentMethodKind` for the scripted session.
    enum DemoMethod: String, Codable, CaseIterable, Identifiable {
        case card
        case applePay
        case savedCard

        var id: String { rawValue }

        /// The SDK method kind for this toggle.
        var kind: PaymentMethodKind {
            switch self {
            case .card: return .card
            case .applePay: return .applePay
            case .savedCard: return .savedCard
            }
        }

        /// A short display label.
        var label: String {
            switch self {
            case .card: return "Card"
            case .applePay: return "Apple Pay"
            case .savedCard: return "Saved card"
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
    /// `.full` drives the backend-layout address form, which reads from the injected
    /// `ScriptableAddressMetadataService`.
    enum DemoAddressMode: String, Codable, CaseIterable, Identifiable {
        case simple
        case full
        case off

        var id: String { rawValue }

        /// A short display label.
        var label: String {
            switch self {
            case .simple: return "Simple (country / line1 / ZIP)"
            case .full: return "Full (backend layout)"
            case .off: return "Off (not collected)"
            }
        }
    }

    // MARK: Scenario

    /// The scripted outcome the mock `submit` lands on (the five demo scripts).
    enum DemoScenario: String, Codable, CaseIterable, Identifiable {
        /// Submit succeeds immediately (terminal success).
        case succeeded
        /// Submit fails immediately (terminal failure).
        case failed
        /// Submit reports processing (non-terminal) -> the UI shows pending.
        case pending
        /// Submit requires further action.
        case requiresAction
        /// Submit times out / network unavailable -> Core enters unknown, then recovers via getResult.
        case networkTimeout

        var id: String { rawValue }

        /// A short display label.
        var label: String {
            switch self {
            case .succeeded: return "Succeeded"
            case .failed: return "Failed"
            case .pending: return "Pending"
            case .requiresAction: return "Requires action"
            case .networkTimeout: return "Network timeout -> unknown"
            }
        }
    }

    // MARK: Stored knobs

    /// Runtime environment.
    var environment: DemoEnvironment
    /// Locale (drives SDK PaymentSheet localization).
    var locale: DemoLocale
    /// ISO 4217 currency code for the scripted session amount.
    var currencyCode: String
    /// The scripted session amount, in minor units (e.g. cents).
    var amountMinorUnits: Int64
    /// The set of enabled payment methods on the scripted session.
    var methods: Set<DemoMethod>
    /// Whether COF (saved cards) is enabled on the scripted session.
    var cofEnabled: Bool
    /// The appearance preset (maps to an `Appearance` at Pay time).
    var appearancePreset: DemoAppearancePreset
    /// The color-scheme override (maps to `Appearance.colorScheme`).
    var colorScheme: DemoColorScheme
    /// The billing address collection mode (maps to `Appearance.billingAddressMode`).
    var billingAddressMode: DemoAddressMode
    /// The shipping address collection mode (maps to `Appearance.shippingAddressMode`).
    var shippingAddressMode: DemoAddressMode
    /// The scripted submit scenario.
    var scenario: DemoScenario
    /// Backend mode. Mock stays the default; the real mode is only reachable in DEBUG builds.
    var mode: DemoMode = .mock
    /// Base URL of the local dev session server (real mode only).
    var devServerURL: String = "http://127.0.0.1:8095"

    /// Default settings mirroring the previous demo backend (42.99 USD, all methods, COF on, succeeded).
    static let `default` = DemoSettings(
        environment: .test,
        locale: .enUS,
        currencyCode: "USD",
        amountMinorUnits: 4299,
        methods: [.card, .applePay, .savedCard],
        cofEnabled: true,
        appearancePreset: .brandDefault,
        colorScheme: .automatic,
        billingAddressMode: .simple,
        shippingAddressMode: .simple,
        scenario: .succeeded
    )
}
