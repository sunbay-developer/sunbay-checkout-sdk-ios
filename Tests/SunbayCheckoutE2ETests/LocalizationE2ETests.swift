import Foundation
import XCTest

@testable import SunbayCheckout
import SunbayCheckoutTestSupport

/// E2E localization assertions: the same `CheckoutError` resolves to different user-facing messages
/// under different locales, driven by `localizedDisplayMessage(using:)` and `LocalizationResolver`
/// (both internal, reachable here via `@testable import SunbayCheckout`).
final class LocalizationE2ETests: XCTestCase {

    /// A payment error localizes to Chinese under `zh-CN` and English under `en-US`, confirming the
    /// Task 5 string table wires `sunbay.error.payment_failed` to both locales. `zh-CN` resolves to
    /// the `zh-Hans` bundle and `en-US` to the `en` bundle via `LocalizationResolver`.
    func test_error_localized_zhVsEn() {
        let e = CheckoutError(code: "PAYMENT_FAILED", message: "dev", category: .payment, traceId: nil)
        XCTAssertEqual(
            e.localizedDisplayMessage(using: LocalizationResolver(explicitLocale: "zh-CN", systemLanguages: [])),
            "支付失败"
        )
        XCTAssertEqual(
            e.localizedDisplayMessage(using: LocalizationResolver(explicitLocale: "en-US", systemLanguages: [])),
            "The payment failed."
        )
    }
}
