import XCTest
@testable import SunbayCheckout

final class CheckoutErrorLocalizationTests: XCTestCase {
    func test_knownCode_zh() {
        let e = CheckoutError(code: "NETWORK_UNAVAILABLE", message: "dev", category: .network, traceId: nil)
        let r = LocalizationResolver(explicitLocale: "zh-CN", systemLanguages: [])
        XCTAssertEqual(e.localizedDisplayMessage(using: r), "网络不可用")
    }

    func test_unknownCode_fallsBackToDeveloperMessage() {
        let e = CheckoutError(code: "SOME_FUTURE_CODE", message: "dev fallback", category: .runtime, traceId: nil)
        let r = LocalizationResolver(explicitLocale: "en-US", systemLanguages: [])
        XCTAssertEqual(e.localizedDisplayMessage(using: r), "dev fallback")
    }
}
