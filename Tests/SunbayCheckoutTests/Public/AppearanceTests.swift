#if canImport(UIKit)
    import XCTest

    @testable import SunbayCheckout

    /// iOS-only (`Appearance` carries UIKit types); vacuous on the macOS host.
    /// Address enabled/style defaults and the session-flag resolution (`.automatic`).
    final class AppearanceTests: XCTestCase {
        func test_addressForms_defaultToEnabled() {
            let appearance = Appearance()
            XCTAssertTrue(appearance.billingAddressEnabled)
            XCTAssertTrue(appearance.shippingAddressEnabled)
            XCTAssertEqual(appearance.billingAddressStyle, .simple)
            XCTAssertEqual(appearance.shippingAddressStyle, .simple)
        }

        func test_resolveAddressMode_automaticFollowsSessionFlagAndEntry() {
            typealias Mode = AddressCollectionMode
            XCTAssertEqual(Mode.resolveAddressMode(.automatic, collect: true, hasUsableEntry: false), .simple)
            XCTAssertEqual(
                Mode.resolveAddressMode(.automatic, collect: true, hasUsableEntry: false, style: .full), .full)
            XCTAssertEqual(
                Mode.resolveAddressMode(.automatic, collect: false, hasUsableEntry: false, style: .full), .off)
            XCTAssertEqual(Mode.resolveAddressMode(.automatic, collect: false, hasUsableEntry: false), .off)
            XCTAssertEqual(Mode.resolveAddressMode(.automatic, collect: true, hasUsableEntry: true), .off)
            XCTAssertEqual(Mode.resolveAddressMode(.automatic, collect: false, hasUsableEntry: true), .off)
        }

        func test_from_enabledFollowsSession_disabledIsOff() {
            XCTAssertEqual(AddressCollectionMode.from(enabled: true), .automatic)
            XCTAssertEqual(AddressCollectionMode.from(enabled: false), .off)
        }

        func test_resolveAddressMode_explicitModesIgnoreSessionFlagAndEntry() {
            typealias Mode = AddressCollectionMode
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
