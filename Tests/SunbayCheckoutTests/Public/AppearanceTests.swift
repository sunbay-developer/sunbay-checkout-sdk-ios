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

        func test_resolveAddressMode_automaticFollowsSessionFlag() {
            XCTAssertEqual(Appearance.AddressCollectionMode.resolveAddressMode(.automatic, collect: true), .full)
            XCTAssertEqual(Appearance.AddressCollectionMode.resolveAddressMode(.automatic, collect: false), .off)
        }

        func test_resolveAddressMode_explicitModesIgnoreSessionFlag() {
            for collect in [true, false] {
                XCTAssertEqual(Appearance.AddressCollectionMode.resolveAddressMode(.simple, collect: collect), .simple)
                XCTAssertEqual(Appearance.AddressCollectionMode.resolveAddressMode(.full, collect: collect), .full)
                XCTAssertEqual(Appearance.AddressCollectionMode.resolveAddressMode(.off, collect: collect), .off)
            }
        }
    }
#endif
