import XCTest
@testable import SunbayCheckout

final class SunbayEndpointsTests: XCTestCase {
    func testLoadSessionOnDev() {
        let url = SunbayEndpoints.url(for: .loadSession(id: "ab"), environment: .dev)
        XCTAssertEqual(url.absoluteString, "https://checkout.sunbay-dev.com/api/checkout/web/session/ab")
    }

    func testSubmitPaymentOnProduction() {
        let url = SunbayEndpoints.url(for: .submitPayment, environment: .production)
        XCTAssertEqual(url.absoluteString, "https://checkout.sunbay.us/api/checkout/web/payment/submit")
    }

    func testPaymentResultOnTest() {
        let url = SunbayEndpoints.url(for: .paymentResult(sessionId: "s1"), environment: .test)
        XCTAssertEqual(url.absoluteString, "https://checkout.sunbay-uat.us/api/checkout/web/payment/result/s1")
    }

    func testCardListOnDev() {
        let url = SunbayEndpoints.url(for: .cardList, environment: .dev)
        XCTAssertEqual(url.absoluteString, "https://checkout.sunbay-dev.com/api/checkout/web/card/list")
    }

    func testAddressCountriesOnDev() {
        let url = SunbayEndpoints.url(for: .addressCountries, environment: .dev)
        XCTAssertEqual(url.absoluteString, "https://checkout.sunbay-dev.com/api/address/country")
    }

    func testAddressCountryConfigEncodesCodeAsOnePathComponent() {
        let url = SunbayEndpoints.url(for: .addressCountryConfig(code: "U/S"), environment: .dev)
        XCTAssertEqual(url.absoluteString, "https://checkout.sunbay-dev.com/api/address/country/U%2FS")
        XCTAssertNil(url.query)
    }

    func testNonASCIIIdIsPercentEncodedAsPureASCII() {
        let url = SunbayEndpoints.url(for: .loadSession(id: "é中"), environment: .dev)
        XCTAssertTrue(url.absoluteString.allSatisfy { $0.isASCII })
        XCTAssertEqual(url.absoluteString, "https://checkout.sunbay-dev.com/api/checkout/web/session/%C3%A9%E4%B8%AD")
    }

    func testEncodeEscapesEverythingExceptAsciiUnreserved() {
        XCTAssertEqual(SunbayEndpoints.encode("é中"), "%C3%A9%E4%B8%AD")
        XCTAssertEqual(SunbayEndpoints.encode("Az09-._~"), "Az09-._~")
    }

    func testIdIsPercentEncodedAsSingleComponent() {
        let url = SunbayEndpoints.url(for: .loadSession(id: "a/b?c d"), environment: .dev)
        XCTAssertTrue(url.absoluteString.contains("a%2Fb%3Fc%20d"))
        XCTAssertEqual(url.path, "/api/checkout/web/session/a/b?c d")
        XCTAssertNil(url.query)
        XCTAssertEqual(url.absoluteString, "https://checkout.sunbay-dev.com/api/checkout/web/session/a%2Fb%3Fc%20d")
    }
}
