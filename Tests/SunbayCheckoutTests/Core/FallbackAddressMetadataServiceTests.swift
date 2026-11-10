import XCTest
@testable import SunbayCheckout

final class FallbackAddressMetadataServiceTests: XCTestCase {
    private struct Boom: Error {}

    private struct StubService: AddressMetadataService {
        var list: AddressCountryList?
        var config: AddressCountryConfig?

        func countries(locale: String?) async throws -> AddressCountryList {
            guard let list else { throw Boom() }
            return list
        }

        func countryConfig(countryCode: String, locale: String?) async throws -> AddressCountryConfig {
            guard let config else { throw Boom() }
            return config
        }
    }

    private let labels = FallbackAddressMetadataService.Labels(
        firstName: "First", lastName: "Last", line1: "Address", postalCode: "ZIP")

    private func makeService(_ inner: StubService) -> FallbackAddressMetadataService {
        FallbackAddressMetadataService(wrapping: inner, labels: labels)
    }

    func testSuccessPassesThroughUnchanged() async throws {
        let list = AddressCountryList(countries: [AddressCountry(code: "ZZ", name: "Zed")], detectedCountry: "ZZ")
        let config = AddressCountryConfig(
            code: "ZZ",
            fields: [.line1: AddressFieldConfig(type: .line1, required: true, pattern: "x", label: "L", placeholder: "P")],
            layout: [[.line1]],
            subdivisions: [])
        let service = makeService(StubService(list: list, config: config))
        let gotList = try await service.countries(locale: "en-US")
        let gotConfig = try await service.countryConfig(countryCode: "ZZ", locale: "en-US")
        XCTAssertEqual(gotList, list)
        XCTAssertEqual(gotConfig, config)
    }

    func testCountriesFailureReturnsSortedList() async throws {
        let service = makeService(StubService())
        let result = try await service.countries(locale: "en-US")
        XCTAssertFalse(result.countries.isEmpty)
        XCTAssertTrue(result.countries.contains { $0.code == "US" })
        let names = result.countries.map { $0.name }
        let locale = Locale(identifier: "en-US")
        XCTAssertEqual(names, names.sorted { $0.compare($1, locale: locale) == .orderedAscending })
        if #available(iOS 16, macOS 13, *) {
            XCTAssertEqual(result.detectedCountry, Locale.current.region?.identifier)
        }
    }

    func testCountriesEmptyInnerFallsBack() async throws {
        let service = makeService(StubService(list: AddressCountryList(countries: [])))
        let result = try await service.countries(locale: "en-US")
        XCTAssertTrue(result.countries.contains { $0.code == "US" })
    }

    func testConfigFailureReturnsMinimalConfig() async throws {
        let service = makeService(StubService())
        let config = try await service.countryConfig(countryCode: "US", locale: "en-US")
        assertMinimal(config, code: "US")
    }

    func testConfigEmptyFieldsFallsBack() async throws {
        let empty = AddressCountryConfig(code: "US", fields: [:], layout: [], subdivisions: [])
        let service = makeService(StubService(config: empty))
        let config = try await service.countryConfig(countryCode: "US", locale: "en-US")
        assertMinimal(config, code: "US")
    }

    private func assertMinimal(_ config: AddressCountryConfig, code: String) {
        XCTAssertEqual(config.code, code)
        XCTAssertEqual(config.layout, [[.firstName, .lastName], [.line1], [.postalCode]])
        XCTAssertEqual(config.subdivisions, [])
        XCTAssertEqual(config.fields[.postalCode]?.required, true)
        XCTAssertNil(config.fields[.postalCode]?.pattern)
        XCTAssertEqual(config.fields[.line1]?.required, false)
        XCTAssertEqual(config.fields[.firstName]?.required, false)
        XCTAssertEqual(config.fields[.lastName]?.required, false)
        XCTAssertEqual(config.fields[.firstName]?.label, "First")
        XCTAssertEqual(config.fields[.lastName]?.placeholder, "Last")
        XCTAssertEqual(config.fields[.line1]?.label, "Address")
        XCTAssertEqual(config.fields[.postalCode]?.placeholder, "ZIP")
    }
}
