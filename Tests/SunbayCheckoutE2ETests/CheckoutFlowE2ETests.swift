import Foundation
import XCTest

@testable import SunbayCheckout
import SunbayCheckoutMocks

/// Protocol-driven e2e cases: drive the Core `CheckoutController` through all five
/// `CheckoutOutcome` results using the public scriptable doubles plus `@testable` controller access.
/// See `E2ESupport.swift` for the `@testable` rationale and the `makeE2E` fixture.
final class CheckoutFlowE2ETests: XCTestCase {

    /// 1. Saved-card submit returns a terminal `S` snapshot -> `.succeeded(txnId:)`.
    func test_confirmSavedCard_succeeded() async {
        let fixture = await makeE2E()
        fixture.paymentService.stubSubmit([
            PaymentSnapshot(sessionId: e2eSessionId, status: .succeeded, txnId: "txn_1")
        ])

        let outcome = await fixture.controller.confirmSavedCard(paymentMethodId: "pm_1")

        guard case .succeeded(let txnId) = outcome else {
            return XCTFail("expected .succeeded, got \(outcome)")
        }
        XCTAssertEqual(txnId, "txn_1")
        XCTAssertEqual(fixture.paymentService.submitCallCount, 1)
    }

    /// 2. Submit returns a terminal `F` snapshot -> `.failed(txnId:error:)`.
    func test_confirmSavedCard_failed() async {
        let fixture = await makeE2E()
        fixture.paymentService.stubSubmit([
            PaymentSnapshot(sessionId: e2eSessionId, status: .failed, txnId: "txn_2")
        ])

        let outcome = await fixture.controller.confirmSavedCard(paymentMethodId: "pm_1")

        guard case .failed(let txnId, let error) = outcome else {
            return XCTFail("expected .failed, got \(outcome)")
        }
        XCTAssertEqual(txnId, "txn_2")
        XCTAssertEqual(error.code, "PAYMENT_FAILED")
        XCTAssertEqual(error.category, .payment)
    }

    /// 3. Submit returns `R` (requiresAction); the action stub returns `.pending` -> `.pending(txnId:)`.
    func test_confirmSavedCard_requiresAction_pending() async {
        let fixture = await makeE2E()
        fixture.actionStub.stubResult(.pending)
        fixture.paymentService.stubSubmit([
            PaymentSnapshot(sessionId: e2eSessionId, status: .requiresAction, txnId: "txn_3")
        ])

        let outcome = await fixture.controller.confirmSavedCard(paymentMethodId: "pm_1")

        guard case .pending(let txnId) = outcome else {
            return XCTFail("expected .pending, got \(outcome)")
        }
        XCTAssertEqual(txnId, "txn_3")
        XCTAssertEqual(fixture.actionStub.handleCallCount, 1)
    }

    /// 4. Submit returns non-terminal `I`; the injected zero-wait poller then observes a terminal
    /// `S` via `getResult` -> `.succeeded(txnId:)`.
    func test_confirmSavedCard_initial_polls_to_succeeded() async {
        let fixture = await makeE2E()
        fixture.paymentService.stubSubmit([
            PaymentSnapshot(sessionId: e2eSessionId, status: .initial, txnId: nil)
        ])
        fixture.paymentService.stubGetResult([
            PaymentSnapshot(sessionId: e2eSessionId, status: .succeeded, txnId: "txn_4")
        ])

        let outcome = await fixture.controller.confirmSavedCard(paymentMethodId: "pm_1")

        guard case .succeeded(let txnId) = outcome else {
            return XCTFail("expected .succeeded, got \(outcome)")
        }
        XCTAssertEqual(txnId, "txn_4")
        XCTAssertGreaterThanOrEqual(fixture.paymentService.getResultCallCount, 1)
    }

    /// 5. Submit throws; the "query first on failure" `getResult` also throws -> `.unknown(sessionId:)`.
    func test_confirmSavedCard_timeout_unknown() async {
        let fixture = await makeE2E()
        let someError = NSError(domain: "E2E", code: 1, userInfo: nil)
        fixture.paymentService.stubSubmitError(someError)
        fixture.paymentService.stubGetResultError(someError)

        let outcome = await fixture.controller.confirmSavedCard(paymentMethodId: "pm_1")

        guard case .unknown(let sessionId) = outcome else {
            return XCTFail("expected .unknown, got \(outcome)")
        }
        XCTAssertEqual(sessionId, e2eSessionId)
        XCTAssertEqual(fixture.paymentService.submitCallCount, 1)
        XCTAssertEqual(fixture.paymentService.getResultCallCount, 1)
    }
}
