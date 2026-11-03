#if canImport(UIKit)
    import UIKit
    import XCTest

    @testable import SunbayCheckout

    /// Unit tests for the tolerant `UIColor(sunbayHex:)` parser (Theme primitive).
    ///
    /// UIKit is iOS-only. When built on the macOS host for `swift test`, this entire file is excluded
    /// by `#if canImport(UIKit)` — it neither compiles nor runs; the real RED/GREEN requires building
    /// against the iOS Simulator SDK (see the task report).
    final class ColorHexTests: XCTestCase {
        func test_parsesSixDigitHex() {
            let c = UIColor(sunbayHex: "#ff6000")
            XCTAssertNotNil(c)
        }

        func test_parsesWithoutHash_andCaseInsensitive() {
            XCTAssertNotNil(UIColor(sunbayHex: "FF6000"))
        }

        func test_parsesEightDigitHexWithAlpha() {
            XCTAssertNotNil(UIColor(sunbayHex: "#ff6000cc"))
        }

        func test_returnsNilOnInvalid() {
            XCTAssertNil(UIColor(sunbayHex: ""))
            XCTAssertNil(UIColor(sunbayHex: "#xyz"))
            XCTAssertNil(UIColor(sunbayHex: "#1234567"))  // 7 digits
        }
    }
#endif
