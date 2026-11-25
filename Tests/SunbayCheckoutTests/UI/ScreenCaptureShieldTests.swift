#if canImport(UIKit)
    import UIKit
    import XCTest

    @testable import SunbayCheckout

    @MainActor
    final class ScreenCaptureShieldTests: XCTestCase {
        private func makeShield(center: NotificationCenter, captured: @escaping () -> Bool = { false })
            -> ScreenCaptureShield
        {
            ScreenCaptureShield(
                backgroundColor: .white, textColor: .gray, message: "hidden",
                notificationCenter: center, isScreenCaptured: captured)
        }

        func test_startsUncovered() {
            let shield = makeShield(center: NotificationCenter())
            XCTAssertFalse(shield.isCovering)
        }

        func test_coversWhileAppIsInactive_andUncoversOnReturn() {
            let center = NotificationCenter()
            let shield = makeShield(center: center)
            center.post(name: UIApplication.willResignActiveNotification, object: nil)
            XCTAssertTrue(shield.isCovering)
            center.post(name: UIApplication.didBecomeActiveNotification, object: nil)
            XCTAssertFalse(shield.isCovering)
        }

        func test_coversWhileScreenIsCaptured() {
            let center = NotificationCenter()
            var captured = false
            let shield = makeShield(center: center, captured: { captured })
            captured = true
            center.post(name: UIScreen.capturedDidChangeNotification, object: nil)
            XCTAssertTrue(shield.isCovering)
            captured = false
            center.post(name: UIScreen.capturedDidChangeNotification, object: nil)
            XCTAssertFalse(shield.isCovering)
        }

        func test_stillCoveredAfterReturn_whenScreenIsStillCaptured() {
            let center = NotificationCenter()
            let shield = makeShield(center: center, captured: { true })
            center.post(name: UIApplication.willResignActiveNotification, object: nil)
            center.post(name: UIApplication.didBecomeActiveNotification, object: nil)
            XCTAssertTrue(shield.isCovering)
        }

        func test_cvvField_blocksCopyAndCut_butPANKeepsThem() {
            let cvv = FloatingLabelTextField(appearance: ResolvedAppearance.resolve(Appearance.default))
            cvv.allowsCopyAndCut = false
            XCTAssertFalse(cvv.canPerformAction(#selector(UIResponderStandardEditActions.copy(_:)), withSender: nil))
            XCTAssertFalse(cvv.canPerformAction(#selector(UIResponderStandardEditActions.cut(_:)), withSender: nil))
        }
    }
#endif
