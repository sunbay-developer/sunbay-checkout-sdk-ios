import Foundation

/// Host configuration entry point for SunbayCheckout (product-spec §2.1).
///
/// This type is part of the public API. The first version only defines and stores these
/// fields, which are consumed by the `SunbayCheckout` entry point; all optional fields
/// default to nil.
public struct CheckoutConfiguration: Sendable, Equatable {
    /// Runtime environment.
    public enum Environment: Sendable, Equatable {
        /// Test environment.
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
    ///   - environment: Runtime environment.
    ///   - applePayMerchantId: Host-configured Apple Pay merchant id; defaults to nil (falls back to the session).
    ///   - appearance: Appearance configuration; defaults to nil.
    ///   - locale: Locale; defaults to nil.
    public init(
        environment: Environment,
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
