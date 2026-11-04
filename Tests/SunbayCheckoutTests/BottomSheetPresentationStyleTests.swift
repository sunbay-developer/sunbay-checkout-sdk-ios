#if canImport(UIKit)
    import UIKit
    import XCTest

    @testable import SunbayCheckout

    /// Pure tests for the presentation-style resolve function (host-runnable; `UIUserInterfaceIdiom`
    /// is a plain enum, no view needed).
    final class BottomSheetPresentationStyleTests: XCTestCase {
        func test_phone_resolvesToCustomBottomSheet() {
            XCTAssertEqual(BottomSheetPresentationStyle.resolve(idiom: .phone), .customBottomSheet)
        }

        func test_unspecified_resolvesToCustomBottomSheet() {
            XCTAssertEqual(BottomSheetPresentationStyle.resolve(idiom: .unspecified), .customBottomSheet)
        }

        func test_tv_resolvesToCustomBottomSheet() {
            XCTAssertEqual(BottomSheetPresentationStyle.resolve(idiom: .tv), .customBottomSheet)
        }

        func test_pad_resolvesToFormSheet() {
            XCTAssertEqual(BottomSheetPresentationStyle.resolve(idiom: .pad), .formSheet)
        }

        func test_mac_resolvesToFormSheet() {
            XCTAssertEqual(BottomSheetPresentationStyle.resolve(idiom: .mac), .formSheet)
        }
    }
#endif
