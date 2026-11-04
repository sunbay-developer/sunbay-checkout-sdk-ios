#if canImport(UIKit)
    import ObjectiveC
    import UIKit
    import XCTest

    @testable import SunbayCheckout

    /// Layout tests for the custom bottom sheet in a REAL `UIWindow`.
    ///
    /// The SwiftPM xctest bundle has no host app, so a genuinely presented sheet cannot be laid out
    /// here. Instead a plain container view (a root view controller's view, with simulated safe-area
    /// insets) stands in for UIKit's transition container, and `BottomSheetLayout` — the exact
    /// constraint installer used by `BottomSheetPresentationController` — installs the presented view.
    @MainActor
    final class BottomSheetLayoutTests: XCTestCase {
        private var window: UIWindow!
        private var host: UIViewController!
        private var container: UIView { host.view }
        /// The container's real top safe-area inset (window safe area + the simulated extra).
        private var safeTop: CGFloat { container.safeAreaInsets.top }

        override func setUp() {
            super.setUp()
            host = UIViewController()
            // On top of whatever safe area the simulator window already provides.
            host.additionalSafeAreaInsets = UIEdgeInsets(top: 20, left: 0, bottom: 20, right: 0)
            window = UIWindow(frame: CGRect(x: 0, y: 0, width: 402, height: 874))
            window.rootViewController = host
            window.makeKeyAndVisible()
            container.layoutIfNeeded()
        }

        override func tearDown() {
            window.isHidden = true
            window = nil
            host = nil
            super.tearDown()
        }

        private func installSheet(
            policy: BottomSheetGeometry.Policy = .init(), cornerRadius: CGFloat = 10, contentHeight: CGFloat = 0
        ) -> (BottomSheetLayout, UIView) {
            let layout = BottomSheetLayout(
                policy: policy, appearanceCornerRadius: cornerRadius, contentHeight: contentHeight)
            let sheet = UIView()
            layout.install(presentedView: sheet, in: container)
            container.layoutIfNeeded()
            return (layout, sheet)
        }

        func test_harness_hasSimulatedSafeAreaAndSize() {
            XCTAssertEqual(container.bounds.size, CGSize(width: 402, height: 874))
            XCTAssertGreaterThanOrEqual(safeTop, 20, "simulated extra safe-area inset is applied")
        }

        func test_install_isFullWidth_andBottomAttached_toContainerEdge() {
            let (_, sheet) = installSheet(contentHeight: 300)
            XCTAssertEqual(sheet.frame.minX, 0)
            XCTAssertEqual(sheet.frame.width, 402)
            XCTAssertEqual(sheet.frame.maxY, container.bounds.maxY, "bottom is the container edge, under the home indicator")
        }

        func test_install_leadingTrailing_followSafeAreaSideInsets() {
            host.additionalSafeAreaInsets = UIEdgeInsets(top: 20, left: 44, bottom: 20, right: 44)
            container.layoutIfNeeded()
            let (_, sheet) = installSheet(contentHeight: 300)
            XCTAssertEqual(sheet.frame.minX, 44)
            XCTAssertEqual(sheet.frame.maxX, 402 - 44)
        }

        func test_install_heightEqualsGeometryResult() {
            let policy = BottomSheetGeometry.Policy(mode: .adaptive)
            let (layout, sheet) = installSheet(policy: policy, contentHeight: 300)
            let expected = BottomSheetGeometry.sheetHeight(
                containerHeight: 874, safeAreaTop: safeTop, keyboardOverlap: 0, contentHeight: 300, policy: policy)
            XCTAssertEqual(expected, 300)
            XCTAssertEqual(sheet.frame.height, expected)
            XCTAssertEqual(layout.heightConstraint?.constant, expected)
            XCTAssertEqual(layout.heightConstraint?.priority, BottomSheetLayout.heightPriority)
            XCTAssertEqual(BottomSheetLayout.heightPriority.rawValue, 999)
        }

        func test_install_unmeasured_usesInitialHeightSoEntranceHasAFrame() {
            let (_, sheet) = installSheet(contentHeight: 0)
            XCTAssertEqual(sheet.frame.height, (874 - safeTop) * BottomSheetGeometry.initialFraction)
        }

        func test_install_roundsTopCornersOnly_withRadiusRule() {
            let (_, sheet) = installSheet(cornerRadius: 10)
            XCTAssertEqual(sheet.layer.maskedCorners, [.layerMinXMinYCorner, .layerMaxXMinYCorner])
            XCTAssertEqual(sheet.layer.cornerRadius, max(10 + 12, 14))
            XCTAssertTrue(sheet.layer.masksToBounds)
        }

        func test_install_cornerRadiusFloorIsFourteen() {
            let (_, sheet) = installSheet(cornerRadius: 0)
            XCTAssertEqual(sheet.layer.cornerRadius, 14)
        }

        func test_contentHeightUpdate_updatesHeightConstraint() {
            let (layout, sheet) = installSheet(contentHeight: 300)
            XCTAssertTrue(layout.setContentHeight(450))
            XCTAssertTrue(layout.applyConstants())
            container.layoutIfNeeded()
            XCTAssertEqual(sheet.frame.height, 450)
            XCTAssertFalse(layout.setContentHeight(450), "an unchanged height is not a change")
        }

        func test_contentHeight_isHardCappedByMaxHeightFraction() {
            let (layout, sheet) = installSheet(policy: .init(maxHeightFraction: 0.5), contentHeight: 5000)
            _ = layout
            XCTAssertEqual(sheet.frame.height, 874 * 0.5, accuracy: 0.01)
        }

        func test_keyboardOverlap_liftsBottom_andShrinksAvailableHeight() {
            let (layout, sheet) = installSheet(contentHeight: 700)
            XCTAssertEqual(sheet.frame.height, 700)
            XCTAssertTrue(layout.setKeyboardOverlap(300))
            layout.applyConstants()
            container.layoutIfNeeded()
            XCTAssertEqual(sheet.frame.maxY, container.bounds.maxY - 300)
            XCTAssertEqual(layout.bottomConstraint?.constant, -300)
            // available = container - safeTop - keyboard
            XCTAssertEqual(sheet.frame.height, 874 - safeTop - 300, accuracy: 0.01)
            XCTAssertGreaterThanOrEqual(sheet.frame.minY, container.safeAreaInsets.top - 0.01)
        }

        func test_keyboardHidden_restoresBottomAndHeight() {
            let (layout, sheet) = installSheet(contentHeight: 700)
            layout.setKeyboardOverlap(300)
            layout.applyConstants()
            container.layoutIfNeeded()
            layout.setKeyboardOverlap(0)
            layout.applyConstants()
            container.layoutIfNeeded()
            XCTAssertEqual(sheet.frame.maxY, container.bounds.maxY)
            XCTAssertEqual(sheet.frame.height, 700)
        }

        func test_largeMode_fillsAvailableHeight() {
            let (_, sheet) = installSheet(policy: .init(mode: .large), contentHeight: 100)
            XCTAssertEqual(sheet.frame.height, 874 - safeTop)
            XCTAssertEqual(sheet.frame.minY, safeTop)
        }

        func test_fixedFractionMode_isFractionOfContainer() {
            let (_, sheet) = installSheet(policy: .init(mode: .fixedFraction(0.5)), contentHeight: 100)
            XCTAssertEqual(sheet.frame.height, 437, accuracy: 0.01)
        }

        func test_height_belowContentMinimum_doesNotConflict_contentMinimumWins() {
            // fixedFraction(0.1) of 874 is ~87pt, below the content's required 500pt minimum.
            let layout = BottomSheetLayout(policy: .init(mode: .fixedFraction(0.1)), appearanceCornerRadius: 10)
            let sheet = UIView()
            let content = UIView()
            content.translatesAutoresizingMaskIntoConstraints = false
            sheet.addSubview(content)
            let minimum = content.heightAnchor.constraint(equalToConstant: 500)
            NSLayoutConstraint.activate([
                content.topAnchor.constraint(equalTo: sheet.topAnchor),
                content.bottomAnchor.constraint(equalTo: sheet.bottomAnchor),
                content.leadingAnchor.constraint(equalTo: sheet.leadingAnchor),
                content.trailingAnchor.constraint(equalTo: sheet.trailingAnchor),
                minimum,
            ])
            layout.install(presentedView: sheet, in: container)
            container.layoutIfNeeded()
            XCTAssertTrue(minimum.isActive, "the content's required constraint is never the one broken")
            XCTAssertEqual(sheet.frame.height, 500, accuracy: 0.01)
        }

        func test_containerResize_recomputesHeight() {
            let layout = BottomSheetLayout(policy: .init(mode: .large), appearanceCornerRadius: 10)
            let sheet = UIView()
            layout.install(presentedView: sheet, in: container)
            container.layoutIfNeeded()
            let controller = BottomSheetPresentationController(
                presentedViewController: UIViewController(), presenting: nil, layout: layout)
            window.frame = CGRect(x: 0, y: 0, width: 874, height: 402)
            container.layoutIfNeeded()
            // The hook UIKit invokes on the presentation controller when the container lays out.
            controller.containerViewWillLayoutSubviews()
            container.layoutIfNeeded()
            XCTAssertEqual(container.bounds.height, 402)
            XCTAssertEqual(sheet.frame.height, 402 - safeTop, accuracy: 0.01)
        }

        // MARK: - Presentation controller wiring

        private func makeController() -> BottomSheetPresentationController {
            BottomSheetPresentationController(
                presentedViewController: UIViewController(), presenting: nil,
                layout: BottomSheetLayout(policy: .init(), appearanceCornerRadius: 10))
        }

        /// Invokes the recognizer's registered target/action pair, as UIKit does on recognition.
        /// Reads UIKit's private `UIGestureRecognizerTarget` ivars (test-only).
        private func fire(_ recognizer: UITapGestureRecognizer) {
            let entries = recognizer.value(forKey: "targets") as? [AnyObject] ?? []
            XCTAssertEqual(entries.count, 1, "the tap recognizer has exactly one target/action")
            for entry in entries {
                guard let targetIvar = class_getInstanceVariable(type(of: entry), "_target"),
                    let actionIvar = class_getInstanceVariable(type(of: entry), "_action"),
                    let target = object_getIvar(entry, targetIvar) as? NSObject
                else { return XCTFail("cannot read UIGestureRecognizerTarget ivars") }
                let base = Unmanaged.passUnretained(entry).toOpaque()
                let offset = ivar_getOffset(actionIvar)
                let action = base.advanced(by: offset).assumingMemoryBound(to: Selector?.self).pointee
                guard let action else { return XCTFail("no action") }
                _ = target.perform(action, with: recognizer)
            }
        }

        func test_dimmingView_hasTapRecognizer_whoseActionReachesHandler() {
            let controller = makeController()
            var taps = 0
            controller.onBackdropTap = { taps += 1 }
            let recognizers = controller.dimmingView.gestureRecognizers?.compactMap { $0 as? UITapGestureRecognizer }
            XCTAssertEqual(recognizers?.count, 1, "the dimming view has exactly one tap recognizer attached")
            guard let recognizer = recognizers?.first else { return }
            fire(recognizer)
            XCTAssertEqual(taps, 1)
        }

        func test_backdropTap_whileTransitioning_isIgnored_andWorksAfterItClears() {
            let controller = makeController()
            var taps = 0
            controller.onBackdropTap = { taps += 1 }
            controller.isTransitioning = true
            controller.simulateBackdropTapForTest()
            XCTAssertEqual(taps, 0)
            controller.isTransitioning = false
            controller.simulateBackdropTapForTest()
            XCTAssertEqual(taps, 1)
        }

        func test_backdropTap_whileSheetHasRunningAnimation_isIgnored_andWorksAfterItClears() {
            let controller = makeController()
            var taps = 0
            controller.onBackdropTap = { taps += 1 }
            let sheetView = controller.presentedViewController.view!
            sheetView.layer.add(CABasicAnimation(keyPath: "opacity"), forKey: "height-change")
            controller.simulateBackdropTapForTest()
            XCTAssertEqual(taps, 0)
            sheetView.layer.removeAllAnimations()
            controller.simulateBackdropTapForTest()
            XCTAssertEqual(taps, 1)
        }

        // MARK: - Transitioning delegate wiring

        func test_transitioningDelegate_buildsControllerWithCallbacksWired_andAnimators() {
            var layoutsMade = 0
            var taps = 0
            var settled = 0
            let delegate = BottomSheetTransitioningDelegate(
                makeLayout: {
                    layoutsMade += 1
                    return BottomSheetLayout(policy: .init(), appearanceCornerRadius: 10)
                },
                onBackdropTap: { taps += 1 },
                onKeyboardSettled: { settled += 1 })
            let presented = UIViewController()
            let source = UIViewController()
            let controller =
                delegate.presentationController(forPresented: presented, presenting: source, source: source)
                as? BottomSheetPresentationController
            XCTAssertNotNil(controller)
            XCTAssertEqual(layoutsMade, 1)
            controller?.onBackdropTap?()
            controller?.onKeyboardSettled?()
            XCTAssertEqual(taps, 1)
            XCTAssertEqual(settled, 1)
            XCTAssertTrue(
                delegate.animationController(forPresented: presented, presenting: source, source: source)
                    is BottomSheetPresentationAnimator)
            XCTAssertTrue(delegate.animationController(forDismissed: presented) is BottomSheetPresentationAnimator)
        }

        // MARK: - Keyboard-already-visible

        func test_resignFirstResponder_dismissesPresenterKeyboardBeforePresenting() {
            let field = UITextField()
            host.view.addSubview(field)
            XCTAssertTrue(field.becomeFirstResponder())
            XCTAssertTrue(field.isFirstResponder)
            PaymentSheet.resignFirstResponder(in: host)
            XCTAssertFalse(field.isFirstResponder)
        }
    }
#endif
