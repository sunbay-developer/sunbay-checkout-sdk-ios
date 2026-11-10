import Foundation

/// An `AddressMetadataService` backed by the Sunbay address endpoints, reached through
/// `SunbayAPIClient` (environment host, enveloped responses).
///
/// Loads `GET /api/address/country` for the country list and `GET /api/address/country/{code}` for a
/// single country config, each with an optional `locale` query item, and decodes the envelope's
/// `data` via `Codable` DTOs into the Core models. The backend `fields` JSON is an **object** keyed by
/// field-type string, mapped here to `[AddressFieldType: AddressFieldConfig]`.
///
/// Errors from the client are rethrown unchanged so the address form can show its own error + retry.
///
/// - Note: UI-agnostic (Foundation only, no UIKit).
struct HTTPAddressMetadataService: AddressMetadataService {
    private let client: SunbayAPIClient

    /// Creates the adapter.
    ///
    /// - Parameter client: The API client bound to the target environment.
    init(client: SunbayAPIClient) {
        self.client = client
    }

    // MARK: - AddressMetadataService

    func countries(locale: String?) async throws -> AddressCountryList {
        let dto: CountryListDTO = try await client.get(.addressCountries, query: Self.query(locale))
        return dto.toModel()
    }

    func countryConfig(countryCode: String, locale: String?) async throws -> AddressCountryConfig {
        let dto: CountryConfigDTO = try await client.get(
            .addressCountryConfig(code: countryCode), query: Self.query(locale))
        return dto.toModel()
    }

    private static func query(_ locale: String?) -> [URLQueryItem] {
        locale.map { [URLQueryItem(name: "locale", value: $0)] } ?? []
    }

    // MARK: - DTOs (wire format -> Core models)

    /// Wire format of the country list `data`.
    private struct CountryListDTO: Decodable, Sendable {
        let countries: [CountryDTO]
        let detectedCountry: String?

        func toModel() -> AddressCountryList {
            AddressCountryList(
                countries: countries.map { AddressCountry(code: $0.code, name: $0.name) },
                detectedCountry: detectedCountry
            )
        }
    }

    /// A country entry.
    private struct CountryDTO: Decodable, Sendable {
        let code: String
        let name: String
    }

    /// Wire format of the country config `data`.
    ///
    /// `fields` is a JSON **object** keyed by field-type string; unknown keys are ignored (downgrade).
    private struct CountryConfigDTO: Decodable, Sendable {
        let code: String
        let fields: [String: FieldConfigDTO]
        let layout: [[String]]
        let subdivisions: [SubdivisionDTO]

        func toModel() -> AddressCountryConfig {
            var mappedFields: [AddressFieldType: AddressFieldConfig] = [:]
            for (key, value) in fields {
                guard let type = AddressFieldType(rawValue: key) else { continue }
                mappedFields[type] = AddressFieldConfig(
                    type: type,
                    required: value.required,
                    pattern: value.pattern,
                    label: value.label,
                    placeholder: value.placeholder
                )
            }
            let mappedLayout = layout.map { row in
                row.compactMap { AddressFieldType(rawValue: $0) }
            }.filter { !$0.isEmpty }
            let mappedSubdivisions = subdivisions.map {
                AddressSubdivision(code: $0.code, name: $0.name)
            }
            return AddressCountryConfig(
                code: code,
                fields: mappedFields,
                layout: mappedLayout,
                subdivisions: mappedSubdivisions
            )
        }
    }

    /// A single field config value within the `fields` object.
    private struct FieldConfigDTO: Decodable, Sendable {
        let required: Bool
        let pattern: String?
        let label: String
        let placeholder: String
    }

    /// A subdivision entry.
    private struct SubdivisionDTO: Decodable, Sendable {
        let code: String
        let name: String
    }
}
