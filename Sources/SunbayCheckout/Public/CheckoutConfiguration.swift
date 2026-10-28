import Foundation

/// Host configuration entry point for SunbayCheckout (product-spec §2.1).
///
/// This type is part of the public API. The first version only defines and stores these
/// fields, which are consumed by the `SunbayCheckout` entry point; all optional fields
/// default to nil.
public struct CheckoutConfiguration: Sendable, Equatable {
    /// Runtime environment.
    ///
    /// Declares which Sunbay environment the host integration targets. Defaults to `production`;
    /// developers pass `dev` / `test` explicitly only when connecting to a non-production backend.
    /// The SDK stores this as the host's declared intent; it does not itself derive backend URLs
    /// from it (the host-injected `PaymentService` / `CofService` adapters own the real endpoints).
    public enum Environment: Sendable, Equatable {
        /// Development environment.
        case dev
        /// Test / UAT environment.
        case test
        /// Production environment.
        case production
    }

    /// Runtime environment.
    public let environment: Environment

    /// Apple Pay merchant id, provided by the host.
    ///
    /// When nil, the id delivered by the session is used instead (two merchant-id models on
    /// the same code path; the host configuration takes precedence, see `resolveMerchantId`).
    public let applePayMerchantId: String?

    /// Appearance / color configuration (first version only stores it, does not consume it).
    public let appearance: Appearance?

    /// Locale (e.g. `"zh-CN"`).
    public let locale: String?

    /// Creates a configuration.
    ///
    /// - Parameters:
    ///   - environment: Runtime environment; defaults to `.production`. Pass `.dev` / `.test` only to target a non-production backend.
    ///   - applePayMerchantId: Host-configured Apple Pay merchant id; defaults to nil (falls back to the session).
    ///   - appearance: Appearance configuration; defaults to nil.
    ///   - locale: Locale; defaults to nil.
    public init(
        environment: Environment = .production,
        applePayMerchantId: String? = nil,
        appearance: Appearance? = nil,
        locale: String? = nil
    ) {
        self.environment = environment
        self.applePayMerchantId = applePayMerchantId
        self.appearance = appearance
        self.locale = locale
    }
}
