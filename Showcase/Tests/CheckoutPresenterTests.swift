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

    func testSystemModeDarkDeviceYieldsDarkAppearance() {
        let theme = ThemeStore()
        theme.mode = .system
        let config = CheckoutPresenter.makeConfiguration(theme: theme, language: .en, systemIsDark: true)
        XCTAssertEqual(config.appearance?.colorScheme, .dark)
    }
}
