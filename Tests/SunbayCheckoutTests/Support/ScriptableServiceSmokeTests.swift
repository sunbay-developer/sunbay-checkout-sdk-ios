import XCTest

import SunbayCheckout
import SunbayCheckoutTestSupport

/// Smoke test: the shared, public-API-only scriptable services are importable without `@testable`
/// and behave as scripted. Runs on the macOS host via `swift test`.
final class ScriptableServiceSmokeTests: XCTestCase {
    func test_scriptableService_returnsStubbedSession() async throws {
        let svc = ScriptablePaymentService()
        svc.stubSession(DemoSessionFactory.make())
        let s = try await svc.loadSession("sid")
        XCTAssertEqual(s.merchantName, DemoSessionFactory.make().merchantName)
    }
}
