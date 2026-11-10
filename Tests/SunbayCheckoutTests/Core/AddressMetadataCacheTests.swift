import XCTest

@testable import SunbayCheckout

/// A scriptable `AddressMetadataService` double that counts calls and can delay responses to
/// force concurrent in-flight overlap. Used to verify the cache's per-key caching and dedup.
private actor SpyAddressService: AddressMetadataService {
    private(set) var countriesCallCount = 0
    private(set) var configCallCount = 0
    private let delayNanos: UInt64

    init(delayMs: UInt64 = 0) {
        self.delayNanos = delayMs * 1_000_000
    }

    func readCountriesCallCount() -> Int { countriesCallCount }
    func readConfigCallCount() -> Int { configCallCount }

    func countries(locale: String?) async throws -> AddressCountryList {
        countriesCallCount += 1
        if delayNanos > 0 {
            try await Task.sleep(nanoseconds: delayNanos)
        }
        return AddressCountryList(
            countries: [AddressCountry(code: "US", name: "United States")],
            detectedCountry: "US"
        )
    }

    func countryConfig(countryCode: String, locale: String?) async throws -> AddressCountryConfig {
        configCallCount += 1
        if delayNanos > 0 {
            try await Task.sleep(nanoseconds: delayNanos)
        }
        return AddressCountryConfig(
            code: countryCode,
            fields: [
                .line1: AddressFieldConfig(
                    type: .line1,
                    required: true,
                    pattern: nil,
                    label: "Address",
                    placeholder: "Street address"
                )
            ],
            layout: [[.line1]],
            subdivisions: []
        )
    }
}

final class AddressMetadataCacheTests: XCTestCase {
    func test_cachesCountryConfigPerLocale() async throws {
        let spy = SpyAddressService()
        let cache = AddressMetadataCache(wrapping: spy)

        _ = try await cache.countryConfig(countryCode: "US", locale: "en")
        _ = try await cache.countryConfig(countryCode: "US", locale: "en")
        let afterSameLocale = await spy.readConfigCallCount()
        XCTAssertEqual(afterSameLocale, 1)  // second served from cache

        _ = try await cache.countryConfig(countryCode: "US", locale: "zh-Hans")
        let afterNewLocale = await spy.readConfigCallCount()
        XCTAssertEqual(afterNewLocale, 2)  // different locale -> new request
    }

    func test_dedupsConcurrentIdenticalRequests() async throws {
        let spy = SpyAddressService(delayMs: 20)
        let cache = AddressMetadataCache(wrapping: spy)

        async let a = cache.countries(locale: "en")
        async let b = cache.countries(locale: "en")
        _ = try await (a, b)

        let count = await spy.readCountriesCallCount()
        XCTAssertEqual(count, 1)
    }

    // MARK: - ReportingAddressMetadataService

    private struct ThrowingAddressService: AddressMetadataService {
        let error: Error
        func countries(locale: String?) async throws -> AddressCountryList { throw error }
        func countryConfig(countryCode: String, locale: String?) async throws -> AddressCountryConfig { throw error }
    }

    func test_reportingDecorator_successPassesThrough() async throws {
        let reporter = DiagnosticsReporter()
        let service = ReportingAddressMetadataService(wrapping: SpyAddressService(), reporter: reporter)
        let list = try await service.countries(locale: nil)
        XCTAssertEqual(list.countries.first?.code, "US")
    }

    func test_reportingDecorator_rethrowsAndReportsOnce() async throws {
        let reporter = DiagnosticsReporter()
        let e = expectation(description: "reported")
        nonisolated(unsafe) var received: [CheckoutDiagnostic] = []
        reporter.handler = { received.append($0); e.fulfill() }
        let thrown = CheckoutError(code: "ADDR_X", message: "m", category: .network, traceId: nil)
        let service = ReportingAddressMetadataService(
            wrapping: ThrowingAddressService(error: thrown), reporter: reporter)
        do {
            _ = try await service.countries(locale: nil)
            XCTFail("expected throw")
        } catch {
            XCTAssertEqual(error as? CheckoutError, thrown)
        }
        await fulfillment(of: [e], timeout: 2)
        XCTAssertEqual(received, [.error(thrown, sessionId: nil)])
    }
}
