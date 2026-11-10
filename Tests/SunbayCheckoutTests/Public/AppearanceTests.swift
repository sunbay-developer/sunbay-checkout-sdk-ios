#if canImport(UIKit)
    import XCTest

    @testable import SunbayCheckout

    /// iOS-only (`Appearance` carries UIKit types); vacuous on the macOS host.
    /// Address collection mode defaults and the session-flag resolution (`.automatic`).
    final class AppearanceTests: XCTestCase {
        func test_addressModes_defaultToAutomatic() {
            let appearance = Appearance()
            XCTAssertEqual(appearance.billingAddressMode, .automatic)
            XCTAssertEqual(appearance.shippingAddressMode, .automatic)
        }

        func test_resolveAddressMode_automaticFollowsSessionFlagAndEntry() {
            typealias Mode = Appearance.AddressCollectionMode
            XCTAssertEqual(Mode.resolveAddressMode(.automatic, collect: true, hasUsableEntry: false), .full)
            XCTAssertEqual(Mode.resolveAddressMode(.automatic, collect: false, hasUsableEntry: false), .off)
            XCTAssertEqual(Mode.resolveAddressMode(.automatic, collect: true, hasUsableEntry: true), .off)
            XCTAssertEqual(Mode.resolveAddressMode(.automatic, collect: false, hasUsableEntry: true), .off)
        }

        func test_resolveAddressMode_explicitModesIgnoreSessionFlagAndEntry() {
            typealias Mode = Appearance.AddressCollectionMode
            for collect in [true, false] {
                for usable in [true, false] {
                    XCTAssertEqual(Mode.resolveAddressMode(.simple, collect: collect, hasUsableEntry: usable), .simple)
                    XCTAssertEqual(Mode.resolveAddressMode(.full, collect: collect, hasUsableEntry: usable), .full)
                    XCTAssertEqual(Mode.resolveAddressMode(.off, collect: collect, hasUsableEntry: usable), .off)
                }
            }
        }
    }
#endif
