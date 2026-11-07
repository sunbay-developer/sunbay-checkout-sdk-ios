import SunbayCheckout
import SwiftUI
import UIKit
import XCTest
@testable import Showcase

final class MerchantThemeTests: XCTestCase {
    func testSystemModeDarkDevicePassesDark() {
        let store = ThemeStore()
        store.mode = .system
        XCTAssertEqual(store.appearance(systemIsDark: true).colorScheme, .dark)
    }

    func testSystemModeLightDevicePassesLight() {
        let store = ThemeStore()
        store.mode = .system
        XCTAssertEqual(store.appearance(systemIsDark: false).colorScheme, .light)
    }

    func testExplicitLightOverridesDarkDevice() {
        let store = ThemeStore()
        store.mode = .light
        XCTAssertEqual(store.appearance(systemIsDark: true).colorScheme, .light)
        store.mode = .dark
        XCTAssertEqual(store.appearance(systemIsDark: false).colorScheme, .dark)
    }

    func testPresetMapsPrimaryAndRadius() {
        let expected: [(ThemePreset, String, CGFloat)] = [
            (.orange, "#ff6000", 10), (.blue, "#2563eb", 3), (.green, "#16a34a", 20),
        ]
        for (preset, hex, radius) in expected {
            let store = ThemeStore()
            store.preset = preset
            let appearance = store.appearance(systemIsDark: false)
            XCTAssertEqual(preset.primaryHex, hex)
            XCTAssertEqual(appearance.cornerRadius, radius)
            XCTAssertEqual(store.cornerRadius, radius)
            XCTAssertNotNil(appearance.colors.primary)
            XCTAssertEqual(appearance.colors.primary, UIColor(sunbayHex: hex))
        }
    }

    /// The window-level style drives every presented screen (Settings sheet, SDK sheet) so they all
    /// follow the merchant mode, including switching back to System.
    func testModeMapsToWindowInterfaceStyle() {
        XCTAssertEqual(ModeChoice.system.userInterfaceStyle, .unspecified)
        XCTAssertEqual(ModeChoice.light.userInterfaceStyle, .light)
        XCTAssertEqual(ModeChoice.dark.userInterfaceStyle, .dark)
    }

    func testApplyingStyleOverridesEveryWindow() {
        let a = UIWindow(), b = UIWindow()
        WindowAppearance.apply(.dark, to: [a, b])
        XCTAssertEqual(a.overrideUserInterfaceStyle, .dark)
        XCTAssertEqual(b.overrideUserInterfaceStyle, .dark)
        WindowAppearance.apply(.unspecified, to: [a, b])
        XCTAssertEqual(a.overrideUserInterfaceStyle, .unspecified, "System must clear the override.")
    }

    /// The Showcase is a coffee shop: no shipping address; billing stays the SDK default.
    func testAppearanceTurnsShippingOffAndKeepsSimpleBilling() {
        let appearance = ThemeStore().appearance(systemIsDark: false)
        XCTAssertEqual(appearance.shippingAddressMode, .off)
        XCTAssertEqual(appearance.billingAddressMode, .simple)
    }
}
