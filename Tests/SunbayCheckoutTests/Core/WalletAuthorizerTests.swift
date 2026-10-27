import XCTest

@testable import SunbayCheckout

final class WalletAuthorizerTests: XCTestCase {
    // MARK: - merchant-id 解析优先级（config over session，§7 / §2.1）

    func test_resolveMerchantId_configuredWinsOverSession() {
        XCTAssertEqual(
            resolveMerchantId(configured: "merchant.host", sessionProvided: "merchant.session"),
            "merchant.host"
        )
    }

    func test_resolveMerchantId_fallsBackToSessionWhenNoConfig() {
        XCTAssertEqual(
            resolveMerchantId(configured: nil, sessionProvided: "merchant.session"),
            "merchant.session"
        )
    }

    func test_resolveMerchantId_nilWhenNeitherProvided() {
        XCTAssertNil(resolveMerchantId(configured: nil, sessionProvided: nil))
    }

    // MARK: - CheckoutConfiguration 字段存储（round-trip）

    func test_checkoutConfiguration_storesValues() {
        let appearance = Appearance(colorPrimary: "#112233")
        let config = CheckoutConfiguration(
            environment: .production,
            applePayMerchantId: "merchant.host",
            appearance: appearance,
            locale: "zh-CN"
        )

        XCTAssertEqual(config.environment, .production)
        XCTAssertEqual(config.applePayMerchantId, "merchant.host")
        XCTAssertEqual(config.appearance, appearance)
        XCTAssertEqual(config.locale, "zh-CN")
    }

    func test_checkoutConfiguration_defaultsAreNil() {
        let config = CheckoutConfiguration(environment: .test)

        XCTAssertEqual(config.environment, .test)
        XCTAssertNil(config.applePayMerchantId)
        XCTAssertNil(config.appearance)
        XCTAssertNil(config.locale)
    }

    // MARK: - canMakePayments 可调用（设备相关值;仅断言不抛、返回 Bool）

    func test_walletAuthorizer_canMakePayments_isCallable() {
        let result: Bool = WalletAuthorizer().canMakePayments()
        // 设备相关的具体 true/false 不做断言;仅验证可调用且返回 Bool。
        _ = result
    }
}
