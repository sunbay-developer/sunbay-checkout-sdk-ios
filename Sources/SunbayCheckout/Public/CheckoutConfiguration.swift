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

    #if canImport(UIKit)
        /// Appearance / color configuration consumed by the UI layer.
        ///
        /// iOS-only: `Appearance` carries `UIColor` / `UIFont` (UIKit), so it — and this property —
        /// is gated by `#if canImport(UIKit)`. Core never consumes appearance, so the rest of the
        /// configuration stays host-compilable.
        public let appearance: Appearance?
    #endif

    /// Locale (e.g. `"zh-CN"`).
    public let locale: String?

    /// Custom title shown at the top of the payment sheet's home page.
    ///
    /// When nil, the home page falls back to the localized default pay title. This only affects the
    /// home page; the new-card subpage and any other page always use their own built-in titles and
    /// are not configurable.
    public let paymentSheetTitle: String?

    /// Custom description shown as a one-line, de-emphasized subtitle under the home-page title.
    ///
    /// When nil, no custom description is shown (the reserved line renders empty). Like
    /// `paymentSheetTitle`, this only affects the home page and never the new-card or other pages.
    public let paymentSheetDescription: String?

    #if canImport(UIKit)
        /// Creates a configuration.
        ///
        /// iOS variant: exposes the UIKit-only `appearance` parameter. Off-UIKit (macOS host) the
        /// parallel initializer below omits `appearance`, so Core stays host-compilable.
        ///
        /// - Parameters:
        ///   - environment: Runtime environment; defaults to `.production`. Pass `.dev` / `.test` only to target a non-production backend.
        ///   - applePayMerchantId: Host-configured Apple Pay merchant id; defaults to nil (falls back to the session).
        ///   - appearance: Appearance configuration; defaults to nil.
        ///   - locale: Locale; defaults to nil.
        ///   - paymentSheetTitle: Custom home-page title; defaults to nil (uses the localized default).
        ///   - paymentSheetDescription: Custom home-page description; defaults to nil (no subtitle).
        public init(
            environment: Environment = .production,
            applePayMerchantId: String? = nil,
            appearance: Appearance? = nil,
            locale: String? = nil,
            paymentSheetTitle: String? = nil,
            paymentSheetDescription: String? = nil
        ) {
            self.environment = environment
            self.applePayMerchantId = applePayMerchantId
            self.appearance = appearance
            self.locale = locale
            self.paymentSheetTitle = paymentSheetTitle
            self.paymentSheetDescription = paymentSheetDescription
        }
    #else
        /// Creates a configuration.
        ///
        /// Off-UIKit (macOS host) variant: `Appearance` is UIKit-only and therefore absent here, so
        /// the host-compilable Core can still construct a configuration.
        ///
        /// - Parameters:
        ///   - environment: Runtime environment; defaults to `.production`. Pass `.dev` / `.test` only to target a non-production backend.
        ///   - applePayMerchantId: Host-configured Apple Pay merchant id; defaults to nil (falls back to the session).
        ///   - locale: Locale; defaults to nil.
        ///   - paymentSheetTitle: Custom home-page title; defaults to nil (uses the localized default).
        ///   - paymentSheetDescription: Custom home-page description; defaults to nil (no subtitle).
        public init(
            environment: Environment = .production,
            applePayMerchantId: String? = nil,
            locale: String? = nil,
            paymentSheetTitle: String? = nil,
            paymentSheetDescription: String? = nil
        ) {
            self.environment = environment
            self.applePayMerchantId = applePayMerchantId
            self.locale = locale
            self.paymentSheetTitle = paymentSheetTitle
            self.paymentSheetDescription = paymentSheetDescription
        }
    #endif
}
