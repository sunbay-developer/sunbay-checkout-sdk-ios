#if canImport(UIKit)
    import UIKit
    import XCTest

    @testable import SunbayCheckout

    @MainActor
    final class AddressSkeletonViewTests: XCTestCase {
        private func fittingHeight(_ view: UIView) -> CGFloat {
            view.systemLayoutSizeFitting(
                CGSize(width: 358, height: 0),
                withHorizontalFittingPriority: .required,
                verticalFittingPriority: .fittingSizeLevel
            ).height
        }

        func test_rowCount_clampsToAtLeastOne() {
            let view = AddressSkeletonView(appearance: .resolve(.default), rowCount: 0)
            XCTAssertEqual(view.rowCount, 1)
            view.rowCount = -3
            XCTAssertEqual(view.rowCount, 1)
        }

        func test_height_matchesRows() {
            let view = AddressSkeletonView(appearance: .resolve(.default), rowCount: 4)
            let expected = 4 * FloatingLabelMetrics.minFieldHeight + 3 * 12
            XCTAssertEqual(fittingHeight(view), expected, accuracy: 0.5)
            view.rowCount = 2
            XCTAssertEqual(fittingHeight(view), 2 * FloatingLabelMetrics.minFieldHeight + 12, accuracy: 0.5)
        }

        func test_shimmers_inWindow_whenMotionAllowed() {
            let view = AddressSkeletonView(
                appearance: .resolve(.default), rowCount: 2, isReduceMotionEnabled: { false })
            let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 800))
            window.addSubview(view)
            XCTAssertTrue(view.isShimmeringForTest)
            view.removeFromSuperview()
            XCTAssertFalse(view.isShimmeringForTest)
        }

        func test_reduceMotion_noShimmer() {
            let view = AddressSkeletonView(
                appearance: .resolve(.default), rowCount: 2, isReduceMotionEnabled: { true })
            let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 800))
            window.addSubview(view)
            XCTAssertFalse(view.isShimmeringForTest)
        }
    }
#endif
