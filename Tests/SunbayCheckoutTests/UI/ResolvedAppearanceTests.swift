#if canImport(UIKit)
    import UIKit
    import XCTest

    @testable import SunbayCheckout

    /// Unit tests for `ResolvedAppearance.resolve`, the pure function that turns the public
    /// (optional, semantic-default) `Appearance` into fully non-optional concrete values the
    /// components consume (Theme layer, design §4.2).
    ///
    /// UIKit is iOS-only. When built on the macOS host for `swift test`, this entire file is excluded
    /// by `#if canImport(UIKit)` — it neither compiles nor runs; the real RED/GREEN requires building
    /// against the iOS Simulator SDK (see the task report).
    final class ResolvedAppearanceTests: XCTestCase {
        func test_defaultsResolveToTokens() {
            let r = ResolvedAppearance.resolve(.default)
            XCTAssertEqual(r.cornerRadius, 10)
            XCTAssertEqual(r.borderWidth, 1)
            XCTAssertEqual(r.density, .comfortable)
            XCTAssertEqual(r.expressPosition, .top)
        }

        func test_merchantColorOverridesSingleLayer() {
            var a = Appearance()
            a.colors.primary = UIColor(sunbayHex: "#2563eb")
            let r = ResolvedAppearance.resolve(a)
            XCTAssertEqual(r.primary, UIColor(sunbayHex: "#2563eb"))
        }

        func test_primaryButtonInheritsAppearanceCornerRadiusWhenNil() {
            var a = Appearance()
            a.cornerRadius = 4
            let r = ResolvedAppearance.resolve(a)
            XCTAssertEqual(r.primaryButtonCornerRadius, 4)
        }
    }
#endif
