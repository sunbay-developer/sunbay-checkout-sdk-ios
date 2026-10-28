import XCTest

@testable import SunbayCheckout

final class WalletAuthorizerTests: XCTestCase {
    // MARK: - merchant-id resolution priority (config over session, §7 / §2.1)

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

    // MARK: - CheckoutConfiguration field storage (round-trip)

    func test_checkoutConfiguration_storesValues() {
        let appearance = Appearance(colorPrimary: "#112233")
        let config = CheckoutConfiguration(
            environment: .dev,
            applePayMerchantId: "merchant.host",
            appearance: appearance,
            locale: "zh-CN"
        )

        XCTAssertEqual(config.environment, .dev)
        XCTAssertEqual(config.applePayMerchantId, "merchant.host")
        XCTAssertEqual(config.appearance, appearance)
        XCTAssertEqual(config.locale, "zh-CN")
    }

    func test_checkoutConfiguration_environmentDefaultsToProduction() {
        // environment defaults to production; developers only pass .dev / .test explicitly.
        let config = CheckoutConfiguration()

        XCTAssertEqual(config.environment, .production)
        XCTAssertNil(config.applePayMerchantId)
        XCTAssertNil(config.appearance)
        XCTAssertNil(config.locale)
    }

    func test_checkoutConfiguration_environmentIsThreeValued() {
        XCTAssertEqual(CheckoutConfiguration(environment: .dev).environment, .dev)
        XCTAssertEqual(CheckoutConfiguration(environment: .test).environment, .test)
        XCTAssertEqual(CheckoutConfiguration(environment: .production).environment, .production)
    }

    // MARK: - canMakePayments is callable (device-dependent value; only assert it does not throw and returns a Bool)

    func test_walletAuthorizer_canMakePayments_isCallable() {
        let result: Bool = WalletAuthorizer().canMakePayments()
        // Do not assert the specific device-dependent true/false; only verify it is callable and returns a Bool.
        _ = result
    }
}
