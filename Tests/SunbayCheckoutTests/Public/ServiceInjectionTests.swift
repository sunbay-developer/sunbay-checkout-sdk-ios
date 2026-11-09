import Foundation
import XCTest

@testable import SunbayCheckout

/// Tests for the public service injection seam (Task 11.5) (pure logic, runs directly on the macOS host, no UIKit dependency).
///
/// Covers:
/// 1. The host services injected via `SunbayCheckout(configuration:paymentService:cofService:)` are
///    actually assembled into `CheckoutController` by `makeController` and drive to a known result.
/// (The plain-init real-backend default is covered by `SunbayCheckoutDefaultWiringTests`.)
final class ServiceInjectionTests: XCTestCase {
    private func makeConfig() -> CheckoutConfiguration {
        CheckoutConfiguration(environment: .test)
    }

    private func makeSession(
        id: String = "sess_inject",
        expiresAt: Date = Date().addingTimeInterval(600)
    ) -> CheckoutSession {
        CheckoutSession(
            id: id,
            amount: Amount(minorUnits: 999, currencyCode: "USD"),
            merchantName: "Acme",
            methods: [.card, .applePay],
            expiresAt: expiresAt,
            rsaPublicKey: nil,
            cofEnabled: true
        )
    }

    // MARK: - 1. The injected services are used by makeController and drive to a known result

    func test_injectedServices_areUsedByController_drivingToSucceeded() async throws {
        let payment = MockPaymentService()
        payment.stubSession(makeSession())
        payment.stubSubmit([PaymentSnapshot(sessionId: "sess_inject", status: .succeeded, txnId: "txn_ok")])
        let cof = MockCofService()

        let checkout = SunbayCheckout(
            configuration: makeConfig(),
            paymentService: payment,
            cofService: cof
        )

        // Assemble the controller with the "injected services" via the internal seam.
        let controller = checkout.makeController(
            credentials: CredentialStore(),
            actionHandler: StubActionHandler()
        )

        _ = try await controller.start(sessionId: "sess_inject", customerAccessSecret: "cas_1")
        let outcome = await controller.confirmSavedCard(paymentMethodId: "pm_1")

        guard case .succeeded(let txnId) = outcome else {
            return XCTFail("the injected MockPaymentService should drive to .succeeded, got \(outcome)")
        }
        XCTAssertEqual(txnId, "txn_ok")
        XCTAssertEqual(payment.submitCallCount, 1, "should submit once via the injected payment service")
        XCTAssertEqual(payment.loadSessionCallCount, 1, "should load the session once via the injected payment service")
    }
}
