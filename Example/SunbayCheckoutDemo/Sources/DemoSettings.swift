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
    /// The scripted submit scenario.
    var scenario: DemoScenario

    /// Default settings mirroring the previous demo backend (42.99 USD, all methods, COF on, succeeded).
    static let `default` = DemoSettings(
        environment: .test,
        locale: .enUS,
        currencyCode: "USD",
        amountMinorUnits: 4299,
        methods: [.card, .applePay, .savedCard],
        cofEnabled: true,
        scenario: .succeeded
    )
}
