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

    func testSwiftUISchemeMapping() {
        let store = ThemeStore()
        store.mode = .system
        XCTAssertNil(store.swiftUIScheme)
        store.mode = .light
        XCTAssertEqual(store.swiftUIScheme, .light)
        store.mode = .dark
        XCTAssertEqual(store.swiftUIScheme, .dark)
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
            XCTAssertEqual(appearance.colors.primary, UIColor(showcaseHex: hex))
        }
    }
}
