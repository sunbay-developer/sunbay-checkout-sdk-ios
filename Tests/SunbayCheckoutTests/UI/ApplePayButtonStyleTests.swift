#if canImport(UIKit)
    import UIKit
    import XCTest

    #if canImport(PassKit)
        import PassKit
    #endif

    @testable import SunbayCheckout

    /// Unit tests for the pure static PassKit style mapping used by `ApplePayButton` (L3).
    ///
    /// These exercise only the pure mapping `ApplePayButton.pkStyle(for:trait:)` — they do not
    /// instantiate the control, so they need neither a device nor PassKit presentation. iOS only
    /// (entirely excluded by `#if canImport(UIKit)` on the macOS host).
    final class ApplePayButtonStyleTests: XCTestCase {
        func test_automaticMapsByTrait() {
            XCTAssertEqual(ApplePayButton.pkStyle(for: .automatic, trait: .dark), .white)
            XCTAssertEqual(ApplePayButton.pkStyle(for: .automatic, trait: .light), .black)
        }

        func test_fixedStylesMapDirectly() {
            XCTAssertEqual(ApplePayButton.pkStyle(for: .black, trait: .light), .black)
            XCTAssertEqual(ApplePayButton.pkStyle(for: .white, trait: .light), .white)
        }
    }
#endif
