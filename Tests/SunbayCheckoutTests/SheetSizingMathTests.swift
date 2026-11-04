import CoreGraphics
import XCTest

@testable import SunbayCheckout

/// Pure tests for the bottom-sheet detent arithmetic (host-runnable, no UIKit).
final class SheetSizingMathTests: XCTestCase {
    func test_clampedHeight_withinRange_passesThrough() {
        XCTAssertEqual(
            SheetSizingMath.clampedHeight(target: 400, minHeight: 200, maxDetent: 800, maxFraction: 0.9), 400)
    }

    func test_clampedHeight_aboveCap_clampsToFractionOfMaxDetent() {
        XCTAssertEqual(
            SheetSizingMath.clampedHeight(target: 790, minHeight: nil, maxDetent: 800, maxFraction: 0.5), 400)
    }

    func test_clampedHeight_belowMin_raisesToMin() {
        XCTAssertEqual(
            SheetSizingMath.clampedHeight(target: 100, minHeight: 300, maxDetent: 800, maxFraction: 0.9), 300)
    }

    func test_clampedHeight_minAboveCap_minWins_butNeverAboveMaxDetent() {
        XCTAssertEqual(
            SheetSizingMath.clampedHeight(target: 100, minHeight: 600, maxDetent: 800, maxFraction: 0.5), 600)
        XCTAssertEqual(
            SheetSizingMath.clampedHeight(target: 100, minHeight: 2000, maxDetent: 800, maxFraction: 0.5), 800)
    }

    func test_clampedHeight_nanAndNegativeMin_treatedAsNoFloor() {
        XCTAssertEqual(
            SheetSizingMath.clampedHeight(target: 100, minHeight: .nan, maxDetent: 800, maxFraction: 0.9), 100)
        XCTAssertEqual(
            SheetSizingMath.clampedHeight(target: 100, minHeight: -50, maxDetent: 800, maxFraction: 0.9), 100)
    }

    func test_clampedHeight_fractionClamped() {
        XCTAssertEqual(
            SheetSizingMath.clampedHeight(target: 5000, minHeight: nil, maxDetent: 800, maxFraction: 7), 800)
        XCTAssertEqual(
            SheetSizingMath.clampedHeight(target: 500, minHeight: nil, maxDetent: 800, maxFraction: -1), 0)
        // NaN fraction falls back to the default 0.9 cap.
        XCTAssertEqual(
            SheetSizingMath.clampedHeight(target: 5000, minHeight: nil, maxDetent: 800, maxFraction: .nan), 720)
    }

    func test_clampedHeight_nanTarget_resolvesToFloor() {
        XCTAssertEqual(
            SheetSizingMath.clampedHeight(target: .nan, minHeight: 250, maxDetent: 800, maxFraction: 0.9), 250)
    }

    func test_targetHeight_fixedFraction_isClamped() {
        XCTAssertEqual(SheetSizingMath.targetHeight(fixedFraction: 0.5, contentHeight: 123, maxDetent: 800), 400)
        XCTAssertEqual(SheetSizingMath.targetHeight(fixedFraction: 3, contentHeight: 123, maxDetent: 800), 800)
        XCTAssertEqual(SheetSizingMath.targetHeight(fixedFraction: -3, contentHeight: 123, maxDetent: 800), 0)
        XCTAssertEqual(SheetSizingMath.targetHeight(fixedFraction: .nan, contentHeight: 123, maxDetent: 800), 400)
    }

    func test_targetHeight_adaptive_usesContentOrHalfBeforeMeasured() {
        XCTAssertEqual(SheetSizingMath.targetHeight(fixedFraction: nil, contentHeight: 321, maxDetent: 800), 321)
        XCTAssertEqual(SheetSizingMath.targetHeight(fixedFraction: nil, contentHeight: 0, maxDetent: 800), 400)
    }
}
