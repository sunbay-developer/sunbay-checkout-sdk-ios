import Foundation

/// Backend address-metadata capability contract (UI-agnostic).
///
/// Corresponds to product-spec §7.5, aligned 1:1 with the existing web checkout `/address/*`
/// responses. The full-mode dynamic address form consumes this to drive its country list and
/// per-country field layout. The first version uses a mock/injected implementation; once the real
/// interface is ready, only the adapter (`HTTPAddressMetadataService`) is replaced, leaving
/// Core/UI untouched.
///
/// - Note: **Public** so the host injects its own implementation (mock or a real backend adapter)
///   alongside `PaymentService` / `CofService`. Address metadata is public (non-sensitive) data.
public protocol AddressMetadataService: Sendable {
    /// Lists the selectable countries plus the backend-detected default country.
    ///
    /// - Parameter locale: The effective locale for localized names (see §7.3); nil uses the
    ///   backend default.
    /// - Returns: The country list and optional detected country.
    func countries(locale: String?) async throws -> AddressCountryList

    /// Loads the address-form configuration for one country.
    ///
    /// - Parameters:
    ///   - countryCode: ISO country code.
    ///   - locale: The effective locale for localized labels/placeholders/names; nil uses the
    ///     backend default.
    /// - Returns: The per-country field config, layout, and subdivisions.
    func countryConfig(countryCode: String, locale: String?) async throws -> AddressCountryConfig
}
