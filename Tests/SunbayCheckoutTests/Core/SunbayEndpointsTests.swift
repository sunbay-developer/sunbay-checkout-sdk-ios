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

    func testIdIsPercentEncodedAsSingleComponent() {
        let url = SunbayEndpoints.url(for: .loadSession(id: "a/b?c d"), environment: .dev)
        XCTAssertTrue(url.absoluteString.contains("a%2Fb%3Fc%20d"))
        XCTAssertEqual(url.path, "/api/checkout/web/session/a/b?c d")
        XCTAssertNil(url.query)
        XCTAssertEqual(url.absoluteString, "https://checkout.sunbay-dev.com/api/checkout/web/session/a%2Fb%3Fc%20d")
    }
}
