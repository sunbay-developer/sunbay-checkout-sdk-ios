import Foundation

/// A fail-soft default `AddressMetadataService` used when the host injects none.
///
/// The SDK ships no real HTTP adapter (the backend contract is undefined, product-spec §7/§8), so
/// `SunbayCheckout` must still construct *something* for the full-mode address form to depend on.
/// This default returns an empty country list and a minimal, dependency-free country config instead
/// of throwing, so a merchant who never configures `.full` address collection (the default is
/// `.simple`, which never calls this) sees no crash and the SDK degrades gracefully.
///
/// It is swapped out the moment the host injects a real `AddressMetadataService`; the UI never
/// distinguishes this default from a real adapter (both arrive wrapped in `AddressMetadataCache`).
///
/// - Note: Internal and UI-agnostic (Foundation only); it must never import UIKit (AGENTS.md §2.6 —
///   Core stays UI-agnostic).
struct EmptyAddressMetadataService: AddressMetadataService {
    /// Returns an empty country list with no detected country.
    func countries(locale: String?) async throws -> AddressCountryList {
        AddressCountryList(countries: [], detectedCountry: nil)
    }

    /// Returns a minimal, empty-layout config for the requested country.
    func countryConfig(countryCode: String, locale: String?) async throws -> AddressCountryConfig {
        AddressCountryConfig(code: countryCode, fields: [:], layout: [], subdivisions: [])
    }
}
