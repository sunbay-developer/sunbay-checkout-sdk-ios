#if canImport(UIKit)
    import UIKit
    import XCTest

    @testable import SunbayCheckout

    /// Dismissal rules of the container (backdrop tap / VoiceOver Escape / form-sheet outside tap).
    /// No presentation is needed: the container's delegate entry points are called directly.
    @MainActor
    final class PaymentSheetContainerDismissalTests: XCTestCase {
        private final class Probe {
            var outcomes: [CheckoutOutcome] = []
            var dismissCount = 0
        }

        private func makeContainer() -> (PaymentSheetContainerViewController, CheckoutContentViewController, Probe) {
            let session = CheckoutSession(
                id: "sess_dismiss",
                amount: Amount(minorUnits: 999, currencyCode: "USD"),
                merchantName: "Acme",
                methods: [.card, .savedCard],
                expiresAt: Date().addingTimeInterval(600),
                rsaPublicKey: nil,
                cofEnabled: false
            )
            let content = CheckoutContentViewController(
                session: session,
                savedCards: [],
                appearance: .resolve(.default),
                localize: { $0 },
                billingMode: .simple,
                shippingMode: .simple,
                addressService: EmptyAddressMetadataService()
            )
            let container = PaymentSheetContainerViewController(
                content: content, appearance: .resolve(.default), colorScheme: .automatic)
            let probe = Probe()
            container.onFinish = { probe.outcomes.append($0) }
            container.performDismiss = { probe.dismissCount += 1 }
            return (container, content, probe)
        }

        private func assertCanceledOnce(_ probe: Probe, file: StaticString = #filePath, line: UInt = #line) {
            XCTAssertEqual(probe.outcomes.count, 1, file: file, line: line)
            if case .canceled? = probe.outcomes.first {} else {
                XCTFail("expected .canceled, got \(probe.outcomes)", file: file, line: line)
            }
            XCTAssertEqual(probe.dismissCount, 1, file: file, line: line)
        }

        func test_phone_usesCustomPresentation_withRetainedTransitioningDelegate() {
            let (container, _, _) = makeContainer()
            XCTAssertEqual(container.presentationStyle, .customBottomSheet)
            XCTAssertEqual(container.modalPresentationStyle, .custom)
            XCTAssertTrue(container.modalPresentationCapturesStatusBarAppearance)
            XCTAssertNotNil(container.transitioningDelegate)
            XCTAssertFalse(container.isModalInPresentation)
        }

        func test_backdropTap_whileEditing_cancelsOnce_andRequestsDismiss() {
            let (container, _, probe) = makeContainer()
            XCTAssertTrue(container.requestCancel())
            assertCanceledOnce(probe)
            // A second tap (e.g. a double tap while dismissing) must not resolve again.
            XCTAssertFalse(container.requestCancel())
            assertCanceledOnce(probe)
        }

        func test_backdropTap_whileProcessing_isIgnored() {
            let (container, content, probe) = makeContainer()
            container.content(content, didChangeProcessing: true)
            XCTAssertFalse(container.requestCancel())
            XCTAssertTrue(probe.outcomes.isEmpty)
            XCTAssertEqual(probe.dismissCount, 0)
        }

        func test_backdropTap_afterSucceeded_isIgnored() {
            let (container, content, probe) = makeContainer()
            container.content(content, didChangeState: .succeeded)
            XCTAssertFalse(container.requestCancel())
            XCTAssertTrue(probe.outcomes.isEmpty)
            XCTAssertEqual(probe.dismissCount, 0)
        }

        func test_backdropTap_allowedAgain_afterProcessingEndsAndStateReturnsToEditing() {
            let (container, content, probe) = makeContainer()
            container.content(content, didChangeProcessing: true)
            container.content(content, didChangeState: .processing)
            XCTAssertFalse(container.requestCancel())
            container.content(content, didChangeProcessing: false)
            container.content(content, didChangeState: .failed)
            XCTAssertTrue(container.canCancel)
            XCTAssertTrue(container.requestCancel())
            assertCanceledOnce(probe)
        }

        func test_backdropTap_allowedAfterStateEditing() {
            let (container, content, probe) = makeContainer()
            container.content(content, didChangeState: .succeeded)
            container.content(content, didChangeState: .editing)
            XCTAssertTrue(container.requestCancel())
            assertCanceledOnce(probe)
        }

        func test_accessibilityEscape_followsSameRule() {
            let (container, content, probe) = makeContainer()
            container.content(content, didChangeProcessing: true)
            XCTAssertFalse(container.accessibilityPerformEscape())
            XCTAssertTrue(probe.outcomes.isEmpty)
            container.content(content, didChangeProcessing: false)
            XCTAssertTrue(container.accessibilityPerformEscape())
            assertCanceledOnce(probe)
            XCTAssertFalse(container.accessibilityPerformEscape(), "once only")
        }

        func test_formSheetDelegate_runsSameRule_andAlwaysRefusesSystemDismissal() {
            let (container, content, probe) = makeContainer()
            let pc = UIPresentationController(presentedViewController: container, presenting: nil)
            container.content(content, didChangeProcessing: true)
            XCTAssertFalse(container.presentationControllerShouldDismiss(pc))
            XCTAssertTrue(probe.outcomes.isEmpty)
            container.content(content, didChangeProcessing: false)
            XCTAssertFalse(container.presentationControllerShouldDismiss(pc), "system dismissal is always refused")
            assertCanceledOnce(probe)
        }

        func test_formSheetDidAttemptToDismiss_runsSameRule() {
            let (container, _, probe) = makeContainer()
            let pc = UIPresentationController(presentedViewController: container, presenting: nil)
            container.presentationControllerDidAttemptToDismiss(pc)
            assertCanceledOnce(probe)
        }

        func test_headerCloseAndBackdrop_resolveOnceTogether() {
            let (container, content, probe) = makeContainer()
            container.contentDidRequestCancel(content)
            XCTAssertFalse(container.requestCancel())
            assertCanceledOnce(probe)
        }
    }
#endif
