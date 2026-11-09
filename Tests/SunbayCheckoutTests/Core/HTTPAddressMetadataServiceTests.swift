import XCTest
@testable import SunbayCheckout

final class HTTPAddressMetadataServiceTests: XCTestCase {
    private var requests: [URLRequest] = []

    override func setUp() {
        super.setUp()
        requests = []
    }

    override func tearDown() {
        StubURLProtocol.handler = nil
        super.tearDown()
    }

    private func service() -> HTTPAddressMetadataService {
        HTTPAddressMetadataService(
            client: SunbayAPIClient(environment: .dev, locale: nil, session: StubURLProtocol.session()))
    }

    private func stub(_ body: String, status: Int = 200) {
        StubURLProtocol.handler = { request in
            self.requests.append(request)
            let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!
            return (response, Data(body.utf8))
        }
    }

    private let countriesJSON = """
        {"code":"0","msg":"ok","data":{"countries":[{"code":"US","name":"United States"},\
        {"code":"CA","name":"Canada"}],"detectedCountry":"US"}}
        """

    private let usConfigJSON = """
        {"code":"0","msg":"ok","data":{"code":"US","fields":{
        "firstName":{"type":"firstName","required":true,"label":"First name","placeholder":"First name"},
        "lastName":{"type":"lastName","required":true,"label":"Last name","placeholder":"Last name"},
        "country":{"type":"country","required":true,"label":"Country","placeholder":"Country"},
        "line1":{"type":"line1","required":true,"label":"Address","placeholder":"Address"},
        "line2":{"type":"line2","required":false,"label":"Apt","placeholder":"Apt"},
        "city":{"type":"city","required":true,"label":"City","placeholder":"City"},
        "state":{"type":"state","required":true,"label":"State","placeholder":"State"},
        "postalCode":{"type":"postalCode","required":true,"pattern":"^\\\\d{5}$","label":"ZIP","placeholder":"ZIP"},
        "mysteryField":{"type":"mysteryField","required":false,"label":"?","placeholder":"?"}},
        "layout":[["firstName","lastName"],["country"],["line1"],["line2"],["city"],["state","postalCode"],["mysteryField"]],
        "subdivisions":[{"code":"CA","name":"California"},{"code":"NY","name":"New York"}]}}
        """

    func testCountriesMapsEntriesAndDetectedCountry() async throws {
        stub(countriesJSON)
        let list = try await service().countries(locale: "en-US")
        XCTAssertEqual(list.countries.map(\.code), ["US", "CA"])
        XCTAssertEqual(list.countries.first?.name, "United States")
        XCTAssertEqual(list.detectedCountry, "US")
        XCTAssertEqual(requests.first?.httpMethod, "GET")
        XCTAssertEqual(requests.first?.url?.host, "checkout.sunbay-dev.com")
        XCTAssertEqual(requests.first?.url?.path, "/api/address/country")
    }

    func testLocaleQueryItemSentWhenPresent() async throws {
        stub(countriesJSON)
        _ = try await service().countries(locale: "en-US")
        XCTAssertEqual(requests.first?.url?.query, "locale=en-US")
    }

    func testLocaleQueryItemAbsentWhenNil() async throws {
        stub(countriesJSON)
        _ = try await service().countries(locale: nil)
        XCTAssertNil(requests.first?.url?.query)
    }

    func testCountryConfigMapsLayoutFieldsAndSubdivisions() async throws {
        stub(usConfigJSON)
        let config = try await service().countryConfig(countryCode: "US", locale: "en-US")
        XCTAssertEqual(requests.first?.url?.path, "/api/address/country/US")
        XCTAssertEqual(requests.first?.url?.query, "locale=en-US")
        XCTAssertEqual(config.code, "US")
        let expectedLayout: [[AddressFieldType]] = [
            [.firstName, .lastName], [.country], [.line1], [.line2], [.city], [.state, .postalCode],
        ]
        XCTAssertEqual(config.layout, expectedLayout)
        XCTAssertEqual(config.fields[.postalCode]?.pattern, "^\\d{5}$")
        XCTAssertEqual(config.fields[.line2]?.required, false)
        XCTAssertEqual(config.fields.count, 8)
        XCTAssertEqual(config.subdivisions.map(\.code), ["CA", "NY"])
        XCTAssertEqual(config.subdivisions.first?.name, "California")
    }

    func testCountryCodeIsPercentEncodedAsOneComponent() async throws {
        stub(usConfigJSON)
        _ = try await service().countryConfig(countryCode: "U/S", locale: nil)
        XCTAssertEqual(requests.first?.url?.absoluteString,
                       "https://checkout.sunbay-dev.com/api/address/country/U%2FS")
    }

    func testBusinessErrorIsRethrownAsCheckoutError() async {
        stub(#"{"code":"NOPE","msg":"no","traceId":"t"}"#)
        do {
            _ = try await service().countries(locale: nil)
            XCTFail("expected throw")
        } catch let error as CheckoutError {
            XCTAssertEqual(error.code, "NOPE")
            XCTAssertEqual(error.category, .payment)
        } catch {
            XCTFail("non-CheckoutError thrown")
        }
    }

    func testServerErrorIsNetworkCheckoutError() async {
        stub("<html/>", status: 502)
        do {
            _ = try await service().countryConfig(countryCode: "US", locale: nil)
            XCTFail("expected throw")
        } catch let error as CheckoutError {
            XCTAssertEqual(error.category, .network)
        } catch {
            XCTFail("non-CheckoutError thrown")
        }
    }
}
