import Foundation
import XCTest

// This e2e target drives the Core `CheckoutController` end to end through all five
// `CheckoutOutcome` results. `CheckoutController`, its `confirm*` methods, the `ActionHandling`
// seam, and `ResultPoller` are all `internal`, so this target uses `@testable import SunbayCheckout`
// to reach them. This is an allowed, deliberate choice: this target is our OWN test harness, not a
// host integrator. The Example app (a separate project) stays strictly public-API-only. The
// scriptable backend doubles (`ScriptablePaymentService` / `ScriptableCofService` /
// `DemoSessionFactory`) are public API and are imported normally from `SunbayCheckoutTestSupport`, so
// only the controller access relies on `@testable`.
@testable import SunbayCheckout
import SunbayCheckoutTestSupport

/// A minimal `ActionHandling` stand-in local to the e2e target.
///
/// The test-internal `StubActionHandler` lives in the `SunbayCheckoutTests` target and is not
/// reachable here, so the e2e target defines its own tiny scripted stub. It is visible because
/// `ActionHandling` / `ActionResult` are reachable through `@testable import SunbayCheckout`. It
/// returns a scripted `ActionResult` (default `.pending`, matching the first-version redirect ->
/// pending behavior) and records the call count for assertions.
final class E2EActionStub: ActionHandling, @unchecked Sendable {
    private let lock = NSLock()
    private var _result: ActionResult
    private var _handleCallCount = 0

    /// Number of times `handle` was invoked.
    var handleCallCount: Int {
        lock.lock(); defer { lock.unlock() }
        return _handleCallCount
    }

    init(result: ActionResult = .pending) {
        _result = result
    }

    /// Scripts the `ActionResult` returned by the next `handle` call.
    func stubResult(_ result: ActionResult) {
        lock.lock(); defer { lock.unlock() }
        _result = result
    }

    func handle(_ action: PaymentAction, sessionId: String) async -> ActionResult {
        lock.lock(); defer { lock.unlock() }
        _handleCallCount += 1
        return _result
    }
}

/// The assembled e2e fixture: a started `CheckoutController` plus the scriptable doubles that back
/// it, so a test can script submit/getResult/action behavior and then drive a confirm path.
struct E2EFixture {
    let controller: CheckoutController
    let paymentService: ScriptablePaymentService
    let cofService: ScriptableCofService
    let actionStub: E2EActionStub
}

/// Shared session id used by `makeE2E`. Kept consistent across `DemoSessionFactory.make(id:)`,
/// `start(sessionId:)`, and every stubbed `PaymentSnapshot.sessionId` so the controller's
/// session-id-threading (submit uses `session.id`) lines up with what tests assert.
let e2eSessionId = "sid"

/// Builds a started e2e fixture.
///
/// Stubs a `DemoSessionFactory` session (id == `e2eSessionId`) on a fresh
/// `ScriptablePaymentService`, constructs a `CheckoutController` via `@testable` with a real
/// `CredentialStore()`, a local `E2EActionStub`, and an injected ZERO-WAIT `ResultPoller` (so the
/// `initial -> poll -> terminal` path never actually backs off), then calls
/// `start(sessionId:customerAccessSecret:)`.
///
/// Each test scripts submit/getResult/action AFTER `makeE2E` returns and BEFORE driving a confirm;
/// `start` only consumes the stubbed session, so later `stubSubmit(...)` / `stubGetResult(...)` /
/// `actionStub.stubResult(...)` calls take effect on the subsequent confirm.
///
/// - Parameter customerAccessSecret: COF credential passed to `start`; defaults to a demo value so
///   the saved-card path has a credential held in memory.
/// - Returns: The started `E2EFixture`.
func makeE2E(customerAccessSecret: String? = "demo_secret") async -> E2EFixture {
    let paymentService = ScriptablePaymentService()
    let cofService = ScriptableCofService()
    let actionStub = E2EActionStub()

    paymentService.stubSession(DemoSessionFactory.make(id: e2eSessionId))

    // Zero-wait poller: deterministic, no real backoff. Driven by the same payment service so
    // `getResult` scripting feeds the poll loop.
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
        customerAccessSecret: customerAccessSecret
    )

    return E2EFixture(
        controller: controller,
        paymentService: paymentService,
        cofService: cofService,
        actionStub: actionStub
    )
}
