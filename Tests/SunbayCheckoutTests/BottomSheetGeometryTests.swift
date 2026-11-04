import CoreGraphics
import XCTest

@testable import SunbayCheckout

/// Pure tests for the custom bottom sheet's geometry (host-runnable, no UIKit).
final class BottomSheetGeometryTests: XCTestCase {
    // MARK: - availableHeight / keyboardOverlap

    func test_availableHeight_subtractsSafeAreaAndKeyboard() {
        XCTAssertEqual(
            BottomSheetGeometry.availableHeight(containerHeight: 800, safeAreaTop: 50, keyboardOverlap: 300), 450)
    }

    func test_availableHeight_neverNegative() {
        XCTAssertEqual(
            BottomSheetGeometry.availableHeight(containerHeight: 800, safeAreaTop: 500, keyboardOverlap: 500), 0)
    }

    func test_keyboardOverlap_computesOverlapWithContainerBottom() {
        let container = CGRect(x: 0, y: 0, width: 400, height: 800)
        let keyboard = CGRect(x: 0, y: 500, width: 400, height: 300)
        XCTAssertEqual(BottomSheetGeometry.keyboardOverlap(containerBounds: container, keyboardFrame: keyboard), 300)
    }

    func test_keyboardOverlap_hiddenKeyboard_isZero() {
        let container = CGRect(x: 0, y: 0, width: 400, height: 800)
        // Hidden keyboard notifications report a frame below/at the screen bottom.
        let keyboard = CGRect(x: 0, y: 800, width: 400, height: 300)
        XCTAssertEqual(BottomSheetGeometry.keyboardOverlap(containerBounds: container, keyboardFrame: keyboard), 0)
    }

    // MARK: - sheetHeight: .adaptive

    func test_sheetHeight_adaptive_withinBounds_usesContentHeight() {
        let height = BottomSheetGeometry.sheetHeight(
            containerHeight: 800, safeAreaTop: 50, keyboardOverlap: 0, contentHeight: 300,
            policy: .init(minHeight: nil, maxHeightFraction: 0.9, mode: .adaptive))
        XCTAssertEqual(height, 300)
    }

    func test_sheetHeight_adaptive_cappedAtMaxHeightFractionOfContainer() {
        // container 800 * 0.5 = 400 cap; available = 800 - 50 = 750, so the cap (400) wins.
        let height = BottomSheetGeometry.sheetHeight(
            containerHeight: 800, safeAreaTop: 50, keyboardOverlap: 0, contentHeight: 700,
            policy: .init(minHeight: nil, maxHeightFraction: 0.5, mode: .adaptive))
        XCTAssertEqual(height, 400, accuracy: 0.01)
    }

    func test_sheetHeight_adaptive_flooredByMinHeight() {
        let height = BottomSheetGeometry.sheetHeight(
            containerHeight: 800, safeAreaTop: 0, keyboardOverlap: 0, contentHeight: 100,
            policy: .init(minHeight: 250, maxHeightFraction: 0.9, mode: .adaptive))
        XCTAssertEqual(height, 250)
    }

    func test_sheetHeight_minAboveMax_minWins_butNeverAboveAvailable() {
        let height = BottomSheetGeometry.sheetHeight(
            containerHeight: 800, safeAreaTop: 0, keyboardOverlap: 0, contentHeight: 100,
            policy: .init(minHeight: 5000, maxHeightFraction: 0.5, mode: .adaptive))
        XCTAssertEqual(height, 800)
    }

    func test_sheetHeight_adaptive_unmeasured_usesInitialFractionOfAvailable() {
        // available = 800 - 0 = 800; initialFraction 0.5 -> 400; cap at 0.9 * 800 = 720, so 400 passes.
        let height = BottomSheetGeometry.sheetHeight(
            containerHeight: 800, safeAreaTop: 0, keyboardOverlap: 0, contentHeight: 0,
            policy: .init(minHeight: nil, maxHeightFraction: 0.9, mode: .adaptive))
        XCTAssertEqual(height, 400)
    }

    // MARK: - sheetHeight: .fixedFraction

    func test_sheetHeight_fixedFraction_isFractionOfContainer() {
        let height = BottomSheetGeometry.sheetHeight(
            containerHeight: 800, safeAreaTop: 0, keyboardOverlap: 0, contentHeight: 999,
            policy: .init(minHeight: nil, maxHeightFraction: 0.9, mode: .fixedFraction(0.6)))
        XCTAssertEqual(height, 480)
    }

    func test_sheetHeight_fixedFraction_isContainerBased_notAvailableBased_withNonZeroSafeArea() {
        // container-based: 800 * 0.6 = 480. An available-based reading would give (800 - 50) * 0.6 = 450.
        let height = BottomSheetGeometry.sheetHeight(
            containerHeight: 800, safeAreaTop: 50, keyboardOverlap: 0, contentHeight: 999,
            policy: .init(minHeight: nil, maxHeightFraction: 0.9, mode: .fixedFraction(0.6)))
        XCTAssertEqual(height, 480, accuracy: 0.001)
    }

    // MARK: - sheetHeight: .large

    func test_sheetHeight_large_isFullAvailableHeight_bypassingMaxFraction() {
        let height = BottomSheetGeometry.sheetHeight(
            containerHeight: 800, safeAreaTop: 50, keyboardOverlap: 0, contentHeight: 0,
            policy: .init(minHeight: nil, maxHeightFraction: 0.1, mode: .large))
        XCTAssertEqual(height, 750)
    }

    // MARK: - keyboard shrinks available height

    func test_sheetHeight_keyboardOverlap_shrinksAvailableHeight_forcesScrolling() {
        // available = 800 - 0 - 400 = 400; content 500 is clamped down to the (now smaller) cap.
        let height = BottomSheetGeometry.sheetHeight(
            containerHeight: 800, safeAreaTop: 0, keyboardOverlap: 400, contentHeight: 500,
            policy: .init(minHeight: nil, maxHeightFraction: 0.9, mode: .adaptive))
        // Exact: min(content 500, cap = min(0.9 * 800, available 400)) = 400.
        XCTAssertEqual(height, 400)
    }

    // MARK: - rotation (container height changes)

    func test_sheetHeight_rotation_recomputesAgainstNewContainerHeight() {
        let portrait = BottomSheetGeometry.sheetHeight(
            containerHeight: 800, safeAreaTop: 0, keyboardOverlap: 0, contentHeight: 0,
            policy: .init(mode: .large))
        let landscape = BottomSheetGeometry.sheetHeight(
            containerHeight: 400, safeAreaTop: 0, keyboardOverlap: 0, contentHeight: 0,
            policy: .init(mode: .large))
        XCTAssertEqual(portrait, 800)
        XCTAssertEqual(landscape, 400)
    }

    // MARK: - degenerate inputs

    func test_sheetHeight_zeroContainer_isZero() {
        let height = BottomSheetGeometry.sheetHeight(
            containerHeight: 0, safeAreaTop: 0, keyboardOverlap: 0, contentHeight: 300,
            policy: .init())
        XCTAssertEqual(height, 0)
    }

    func test_sheetHeight_nanContentHeight_fallsBackToInitialFraction() {
        let height = BottomSheetGeometry.sheetHeight(
            containerHeight: 800, safeAreaTop: 0, keyboardOverlap: 0, contentHeight: .nan,
            policy: .init())
        XCTAssertEqual(height, 400)
    }

    func test_sheetHeight_nanContainerHeight_isZero() {
        let height = BottomSheetGeometry.sheetHeight(
            containerHeight: .nan, safeAreaTop: 0, keyboardOverlap: 0, contentHeight: 300,
            policy: .init())
        XCTAssertEqual(height, 0)
    }

    // MARK: - corner radius

    func test_cornerRadius_isAppearancePlusTwelve() {
        XCTAssertEqual(BottomSheetGeometry.cornerRadius(appearanceCornerRadius: 10), 22)
    }

    func test_cornerRadius_hasAFloorOfFourteen() {
        XCTAssertEqual(BottomSheetGeometry.cornerRadius(appearanceCornerRadius: 0), 14)
        XCTAssertEqual(BottomSheetGeometry.cornerRadius(appearanceCornerRadius: -100), 14)
    }
}
