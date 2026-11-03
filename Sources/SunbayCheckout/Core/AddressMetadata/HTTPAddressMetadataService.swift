import Foundation

/// A thin `URLSession` adapter implementing `AddressMetadataService` against the existing checkout
/// `/address/*` endpoints (product-spec §7.5).
///
/// Builds `{baseURL}/address/country?locale=&countries=` for the country list and
/// `{baseURL}/address/country/{code}?locale=` for a single country config, and decodes the JSON via
/// `Codable` DTOs into the Core models. The backend `fields` JSON is an **object** keyed by
/// field-type string, mapped here to `[AddressFieldType: AddressFieldConfig]`.
///
/// - Note: UI-agnostic (Foundation / URLSession only, no UIKit). The `baseURL` is host-injected.
///   Not wired to real data this phase — demo/tests use an injected mock double.
struct HTTPAddressMetadataService: AddressMetadataService {
    /// The backend base URL (such as `https://api.example.com`).
    private let baseURL: URL
    /// The URL session used for requests.
    private let session: URLSession

    /// Creates an HTTP address-metadata adapter.
    ///
    /// - Parameters:
    ///   - baseURL: The backend base URL.
    ///   - session: The URL session, defaults to `.shared`.
    init(baseURL: URL, session: URLSession = .shared) {
        self.baseURL = baseURL
        self.session = session
    }

    // MARK: - AddressMetadataService

    func countries(locale: String?) async throws -> AddressCountryList {
        let url = try makeURL(
            path: "address/country",
            queryItems: [
                locale.map { URLQueryItem(name: "locale", value: $0) }
            ].compactMap { $0 }
        )
        let dto: CountryListDTO = try await get(url)
        return dto.toModel()
    }

    func countryConfig(countryCode: String, locale: String?) async throws -> AddressCountryConfig {
        let url = try makeURL(
            path: "address/country/\(countryCode)",
            queryItems: [
                locale.map { URLQueryItem(name: "locale", value: $0) }
            ].compactMap { $0 }
        )
        let dto: CountryConfigDTO = try await get(url)
        return dto.toModel()
    }

    // MARK: - Networking

    /// Builds a URL by appending `path` to `baseURL` and adding query items.
    private func makeURL(path: String, queryItems: [URLQueryItem]) throws -> URL {
        let base = baseURL.appendingPathComponent(path)
        guard var components = URLComponents(url: base, resolvingAgainstBaseURL: false) else {
            throw URLError(.badURL)
        }
        if !queryItems.isEmpty {
            components.queryItems = queryItems
        }
        guard let url = components.url else {
            throw URLError(.badURL)
        }
        return url
    }

    /// Performs a GET and decodes the JSON body into `T`.
    private func get<T: Decodable>(_ url: URL) async throws -> T {
        let (data, response) = try await session.data(from: url)
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw URLError(.badServerResponse)
        }
        return try JSONDecoder().decode(T.self, from: data)
    }

    // MARK: - DTOs (wire format -> Core models)

    /// Wire format of `/address/country`.
    private struct CountryListDTO: Decodable {
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
    private struct CountryDTO: Decodable {
        let code: String
        let name: String
    }

    /// Wire format of `/address/country/{code}`.
    ///
    /// `fields` is a JSON **object** keyed by field-type string; unknown keys are ignored (downgrade).
    private struct CountryConfigDTO: Decodable {
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
            }
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
    private struct FieldConfigDTO: Decodable {
        let required: Bool
        let pattern: String?
        let label: String
        let placeholder: String
    }

    /// A subdivision entry.
    private struct SubdivisionDTO: Decodable {
        let code: String
        let name: String
    }
}
