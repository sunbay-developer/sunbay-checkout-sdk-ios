import Foundation

/// Decorator that substitutes a local, minimal address metadata when the wrapped service cannot
/// provide usable data.
///
/// The fallback engages when the inner service:
/// - throws any error, or
/// - succeeds but returns an empty country list (`countries`) or a config whose `fields` is empty
///   (`countryConfig`). This covers `EmptyAddressMetadataService`, the default when a host injects
///   no service, which returns such empty values without throwing.
///
/// A non-empty inner result is passed through unchanged.
///
/// The fallback country list is built from `Locale.isoRegionCodes`, sorted by localized name. The
/// fallback config is a minimal form: first/last name (optional), address line 1 (required) and
/// postal code (required, no pattern), with labels supplied by the caller.
///
/// - Note: Used by simple mode only. Full mode keeps its failed state and retry, and must not wrap
///   its service with this type.
struct FallbackAddressMetadataService: AddressMetadataService {
    /// Localized labels used for the fallback config fields (also used as placeholders).
    struct Labels: Sendable {
        let firstName: String
        let lastName: String
        let line1: String
        let postalCode: String
    }

    private let inner: any AddressMetadataService
    private let labels: Labels

    init(wrapping inner: any AddressMetadataService, labels: Labels) {
        self.inner = inner
        self.labels = labels
    }

    func countries(locale: String?) async throws -> AddressCountryList {
        if let list = try? await inner.countries(locale: locale), !list.countries.isEmpty {
            return list
        }
        let displayLocale = Locale(identifier: locale ?? Locale.current.identifier)
        let countries = Locale.isoRegionCodes
            .map { code in
                AddressCountry(code: code, name: displayLocale.localizedString(forRegionCode: code) ?? code)
            }
            .sorted { $0.name.compare($1.name, locale: displayLocale) == .orderedAscending }
        return AddressCountryList(countries: countries, detectedCountry: Self.currentRegionCode())
    }

    /// The device region code; `Locale.region` needs iOS 16 while the package targets iOS 15.
    private static func currentRegionCode() -> String? {
        if #available(iOS 16, macOS 13, *) {
            return Locale.current.region?.identifier
        }
        return Locale.current.regionCode
    }

    func countryConfig(countryCode: String, locale: String?) async throws -> AddressCountryConfig {
        if let config = try? await inner.countryConfig(countryCode: countryCode, locale: locale),
           !config.fields.isEmpty {
            return config
        }
        return AddressCountryConfig(
            code: countryCode,
            fields: [
                .firstName: field(.firstName, required: false, text: labels.firstName),
                .lastName: field(.lastName, required: false, text: labels.lastName),
                .line1: field(.line1, required: true, text: labels.line1),
                .postalCode: field(.postalCode, required: true, text: labels.postalCode)
            ],
            layout: [[.firstName, .lastName], [.line1], [.postalCode]],
            subdivisions: [])
    }

    private func field(_ type: AddressFieldType, required: Bool, text: String) -> AddressFieldConfig {
        AddressFieldConfig(type: type, required: required, pattern: nil, label: text, placeholder: text)
    }
}
