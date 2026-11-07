import SunbayCheckout
import XCTest
@testable import Showcase

final class CheckoutPresenterTests: XCTestCase {
    func testLocaleFollowsLanguage() {
        let theme = ThemeStore()
        XCTAssertEqual(
            CheckoutPresenter.makeConfiguration(theme: theme, language: .zh, systemIsDark: false).locale,
            "zh-CN"
        )
        XCTAssertEqual(
            CheckoutPresenter.makeConfiguration(theme: theme, language: .en, systemIsDark: false).locale,
            "en-US"
        )
    }

    func testConfigurationUsesSuppliedMerchantId() {
        let theme = ThemeStore()
        let custom = CheckoutPresenter.makeConfiguration(
            theme: theme, language: .en, systemIsDark: false, merchantId: "merchant.com.example.custom")
        XCTAssertEqual(custom.applePayMerchantId, "merchant.com.example.custom")
        let fallback = CheckoutPresenter.makeConfiguration(theme: theme, language: .en, systemIsDark: false)
        XCTAssertEqual(fallback.applePayMerchantId, "merchant.native.com.sunbay.dev")
    }

    func testSystemModeDarkDeviceYieldsDarkAppearance() {
        let theme = ThemeStore()
        theme.mode = .system
        let config = CheckoutPresenter.makeConfiguration(theme: theme, language: .en, systemIsDark: true)
        XCTAssertEqual(config.appearance?.colorScheme, .dark)
    }
}
