import XCTest
@testable import SunbayCheckout

final class CheckoutErrorLocalizationTests: XCTestCase {
    func test_knownCode_zh() {
        let e = CheckoutError(code: "NETWORK_UNAVAILABLE", message: "dev", category: .network, traceId: nil)
        let r = LocalizationResolver(explicitLocale: "zh-CN", systemLanguages: [])
        XCTAssertEqual(e.localizedDisplayMessage(using: r), "网络不可用")
    }

    func test_paymentFailedWithServerReason_displaysReason() {
        let r = LocalizationResolver(explicitLocale: "en-US", systemLanguages: [])
        let withReason = CheckoutError(code: "PAYMENT_FAILED", message: "Card declined", category: .payment, traceId: nil)
        XCTAssertEqual(withReason.localizedDisplayMessage(using: r), "Card declined")

        let withDefault = CheckoutError(
            code: "PAYMENT_FAILED", message: CheckoutErrors.defaultPaymentFailedMessage,
            category: .payment, traceId: nil)
        XCTAssertEqual(
            withDefault.localizedDisplayMessage(using: r),
            r.localized("sunbay.error.payment_failed", ""))
        XCTAssertNotEqual(withDefault.localizedDisplayMessage(using: r), "sunbay.error.payment_failed")
    }

    func test_unknownCode_fallsBackToDeveloperMessage() {
        let e = CheckoutError(code: "SOME_FUTURE_CODE", message: "dev fallback", category: .runtime, traceId: nil)
        let r = LocalizationResolver(explicitLocale: "en-US", systemLanguages: [])
        XCTAssertEqual(e.localizedDisplayMessage(using: r), "dev fallback")
    }
}
