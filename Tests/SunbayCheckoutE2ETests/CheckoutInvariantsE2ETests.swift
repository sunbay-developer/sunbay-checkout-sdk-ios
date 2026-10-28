import Foundation
import XCTest

@testable import SunbayCheckout
import SunbayCheckoutTestSupport

/// E2E invariant cases for the Core `CheckoutController`: single-active guard (idempotency against
/// concurrent confirms), "query first on submit failure", and the COF-disabled downgrade.
///
/// Uses the public scriptable doubles plus `@testable` controller access, same as
/// `CheckoutFlowE2ETests`. See `E2ESupport.swift` for the `@testable` rationale and the `makeE2E`
/// fixture.
final class CheckoutInvariantsE2ETests: XCTestCase {

    /// Single-active invariant (spec 4.2): while one confirm is in-flight, a second concurrent
    /// confirm is rejected with `.failed` carrying `ALREADY_PRESENTING`.
    ///
    /// To make the overlap deterministic without `sleep`s in the test body, the shared
    /// `ScriptablePaymentService` is scripted with a real but short `submit` delay so the first
    /// confirm stays inside `beginAttempt()`'s occupied window while the second confirm enters. A
    /// terminal `S` snapshot is also stubbed so the winning confirm resolves (both confirms share
    /// the same service). Exactly one of the two outcomes must be the rejection; the other proceeds.
    func test_secondConcurrentConfirm_isRejected_alreadyPresenting() async {
        let fixture = await makeE2E()
        // Short real delay creates the in-flight window deterministically (seconds; Task 6 delay is
        // a TimeInterval). Kept small to avoid slowing the suite while still guaranteeing overlap.
        fixture.paymentService.stubSubmitDelay(0.4)
        fixture.paymentService.stubSubmit([
            PaymentSnapshot(sessionId: e2eSessionId, status: .succeeded, txnId: "txn_win")
        ])

        // Launch both confirms concurrently; the actor serializes entry, so the second to enter
        // sees the active lock occupied by the first (still delayed inside submit).
        async let first = fixture.controller.confirmSavedCard(paymentMethodId: "pm_1")
        async let second = fixture.controller.confirmSavedCard(paymentMethodId: "pm_2")
        let outcomes = await [first, second]

        let rejected = outcomes.filter { outcome -> Bool in
            if case .failed(_, let error) = outcome {
                return error.code == "ALREADY_PRESENTING"
            }
            return false
        }
        XCTAssertEqual(
            rejected.count, 1,
            "exactly one concurrent confirm must be rejected with ALREADY_PRESENTING, got \(outcomes)"
        )
        // The rejected one must be .runtime; the other must have proceeded to submit.
        if case .failed(let txnId, let error) = rejected.first {
            XCTAssertNil(txnId)
            XCTAssertEqual(error.category, .runtime)
        } else {
            XCTFail("expected the rejected outcome to be .failed ALREADY_PRESENTING")
        }
        // The winner actually reached the backend exactly once (the rejected confirm never submits).
        XCTAssertEqual(fixture.paymentService.submitCallCount, 1)
    }

    /// "Query first on submit failure" invariant (spec 4.2 / 4.3): when `submit` throws, the
    /// controller queries `getResult` exactly once and never resubmits; if that query also fails the
    /// outcome is `.unknown(sessionId:)`.
    ///
    /// Overlaps `CheckoutFlowE2ETests` case 5, but the assertion focus here is the call-count
    /// invariant (`getResultCallCount == 1`, `submitCallCount == 1`), per the Task 8 brief.
    func test_submitThrows_queriesOnce_thenUnknown() async {
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

    /// COF-disabled downgrade invariant (spec 2.2 / Task 6): when the session's `cofEnabled` is
    /// false, `listSavedCards()` returns `[]` and never calls `CofService` (`listCallCount == 0`).
    ///
    /// `makeE2E` does not accept a custom session, so this test constructs the controller inline
    /// (mirroring `makeE2E`'s body) with a `cofEnabled: false` session. Inlining is the lower-risk
    /// option: it leaves `makeE2E` and Task 7's tests untouched.
    func test_cof_disabled_listSavedCards_empty() async {
        let paymentService = ScriptablePaymentService()
        let cofService = ScriptableCofService()
        let actionStub = E2EActionStub()

        paymentService.stubSession(DemoSessionFactory.make(id: e2eSessionId, cofEnabled: false))
        let poller = ResultPoller(service: paymentService, sleep: { _ in })
        let controller = CheckoutController(
            paymentService: paymentService,
            cofService: cofService,
            credentials: CredentialStore(),
            actionHandler: actionStub,
            poller: poller
        )
        _ = try? await controller.start(
            sessionId: e2eSessionId,
            customerAccessSecret: "demo_secret"
        )

        let cards = await controller.listSavedCards()

        XCTAssertTrue(cards.isEmpty, "expected [] when COF is disabled, got \(cards)")
        XCTAssertEqual(
            cofService.listCallCount, 0,
            "CofService.listPaymentMethods must never be called when COF is disabled"
        )
    }
}
