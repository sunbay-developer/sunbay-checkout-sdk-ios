import Foundation
import XCTest
@testable import SunbayCheckout
import SunbayCheckoutTestSupport

/// Opt-in tests against the real dev backend. They skip unless `SUNBAY_DEV_SERVER_URL` is set and
/// the environment under test is `.dev` or `.test`. Card values are read from the environment and
/// never logged.
final class RealAPIPaymentTests: XCTestCase {
    /// The environment under test.
    private let environment: CheckoutConfiguration.Environment = .dev

    private struct NoopActionHandler: ActionHandling {
        func handle(_ action: PaymentAction, sessionId: String) async -> ActionResult { .pending }
    }

    private func devServerURL() throws -> URL {
        let raw = ProcessInfo.processInfo.environment["SUNBAY_DEV_SERVER_URL"]
        try XCTSkipIf(raw == nil || raw?.isEmpty == true, "SUNBAY_DEV_SERVER_URL is not set.")
        try XCTSkipIf(environment != .dev && environment != .test,
                      "Real-API tests run only against dev or test.")
        guard let raw, let url = URL(string: raw) else {
            throw XCTSkip("SUNBAY_DEV_SERVER_URL is not a valid URL.")
        }
        return url
    }

    private func makeService(credentials: CredentialStore) -> HTTPPaymentService {
        let client = SunbayAPIClient(environment: environment, locale: "en-US")
        return HTTPPaymentService(client: client, credentials: credentials, deviceInfo: { nil })
    }

    func testLoadSessionAgainstDev() async throws {
        let url = try devServerURL()
        // 1.05 major units -> orderAmount 105 minor, tax round(105 * 0.08) = 8, total 113 minor.
        let dev = try await DevSessionClient(serverURL: url).createSession(amountMajorUnits: 1.05)
        let credentials = CredentialStore()
        await credentials.hold(checkoutClientSecret: dev.checkoutClientSecret)
        let session = try await makeService(credentials: credentials).loadSession(dev.sessionId)

        XCTAssertEqual(session.id, dev.sessionId)
        XCTAssertNotNil(session.rsaPublicKey)
        XCTAssertTrue(session.methods.contains(.card))
        XCTAssertTrue(session.cofEnabled)
        // Settles the minor-vs-major ambiguity: a minor-unit reading predicts 113.
        XCTAssertEqual(session.amount.minorUnits, 113, "Observed minor units: \(session.amount.minorUnits)")
    }

    func testExpiredOrUnknownSessionIsRejected() async throws {
        let url = try devServerURL()
        let dev = try await DevSessionClient(serverURL: url).createSession()
        let credentials = CredentialStore()
        await credentials.hold(checkoutClientSecret: dev.checkoutClientSecret)
        do {
            _ = try await makeService(credentials: credentials).loadSession("does-not-exist")
            XCTFail("Expected loadSession to throw for an unknown session.")
        } catch let error as CheckoutError {
            XCTAssertNotEqual(error.category, .network, "Unexpected network-category error: \(error.code)")
        }
    }

    func testNewCardPaymentReachesTerminalState() async throws {
        let url = try devServerURL()
        let env = ProcessInfo.processInfo.environment
        guard let number = env["SUNBAY_TEST_CARD_NUMBER"], let month = env["SUNBAY_TEST_CARD_EXPIRY_MM"],
              let year = env["SUNBAY_TEST_CARD_EXPIRY_YYYY"], let cvv = env["SUNBAY_TEST_CARD_CVV"] else {
            throw XCTSkip("SUNBAY_TEST_CARD_* environment variables are not set.")
        }
        let dev = try await DevSessionClient(serverURL: url).createSession()
        let credentials = CredentialStore()
        let controller = CheckoutController(
            paymentService: makeService(credentials: credentials),
            cofService: ScriptableCofService(),
            credentials: credentials,
            actionHandler: NoopActionHandler())
        _ = try await controller.start(sessionId: dev.sessionId,
                                       customerAccessSecret: dev.customerAccessSecret,
                                       checkoutClientSecret: dev.checkoutClientSecret)
        let outcome = await controller.confirmNewCard(
            CardInput(cardNumber: number, expiryMonth: month, expiryYear: year, cvv: cvv), save: false)
        guard case .succeeded(let txnId) = outcome else {
            return XCTFail("Expected .succeeded, got a different outcome.")
        }
        let snapshot = try await controller.retrievePayment(sessionId: dev.sessionId)
        XCTAssertEqual(snapshot.status, .succeeded)
        XCTAssertEqual(snapshot.txnId, txnId)
    }
}
