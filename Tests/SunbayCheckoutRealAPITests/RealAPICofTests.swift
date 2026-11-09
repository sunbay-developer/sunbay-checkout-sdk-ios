import Foundation
import XCTest
@testable import SunbayCheckout
import SunbayCheckoutTestSupport

/// Opt-in card-on-file tests against the real dev backend. They skip unless `SUNBAY_DEV_SERVER_URL`
/// is set. Card values and secrets are never logged; failure messages name only the failed step and
/// the outcome case or error code.
final class RealAPICofTests: XCTestCase {
    private let environment: CheckoutConfiguration.Environment = .dev

    private struct NoopActionHandler: ActionHandling {
        func handle(_ action: PaymentAction, sessionId: String) async -> ActionResult { .pending }
    }

    private struct TestCard {
        let number: String, month: String, year: String, cvv: String
    }

    private func devServerURL() throws -> URL {
        let raw = ProcessInfo.processInfo.environment["SUNBAY_DEV_SERVER_URL"]
        try XCTSkipIf(raw == nil || raw?.isEmpty == true, "SUNBAY_DEV_SERVER_URL is not set.")
        guard let raw, let url = URL(string: raw) else {
            throw XCTSkip("SUNBAY_DEV_SERVER_URL is not a valid URL.")
        }
        return url
    }

    private func testCard() throws -> TestCard {
        let env = ProcessInfo.processInfo.environment
        guard let number = env["SUNBAY_TEST_CARD_NUMBER"], let month = env["SUNBAY_TEST_CARD_EXPIRY_MM"],
              let year = env["SUNBAY_TEST_CARD_EXPIRY_YYYY"], let cvv = env["SUNBAY_TEST_CARD_CVV"] else {
            throw XCTSkip("SUNBAY_TEST_CARD_* environment variables are not set.")
        }
        return TestCard(number: number, month: month, year: year, cvv: cvv)
    }

    private func makeClient() -> SunbayAPIClient {
        SunbayAPIClient(environment: environment, locale: "en-US")
    }

    private func makeController(credentials: CredentialStore) -> CheckoutController {
        CheckoutController(
            paymentService: HTTPPaymentService(client: makeClient(), credentials: credentials, deviceInfo: { nil }),
            cofService: HTTPCofService(client: makeClient()),
            credentials: credentials,
            actionHandler: NoopActionHandler(),
            cardOnFile: CardOnFileOptions())
    }

    /// Names the outcome case (and error code for failures) without any payload.
    private func describe(_ outcome: CheckoutOutcome) -> String {
        switch outcome {
        case .succeeded: return "succeeded"
        case .failed(_, let error): return "failed(code: \(error.code))"
        case .canceled: return "canceled"
        case .pending: return "pending"
        case .unknown: return "unknown"
        }
    }

    private func newSession() async throws -> (DevSession, String) {
        let dev = try await DevSessionClient(serverURL: try devServerURL()).createSession()
        guard let secret = dev.customerAccessSecret else {
            throw XCTSkip("The dev server did not return a customerAccessSecret.")
        }
        return (dev, secret)
    }

    func testCardListWithValidSecretReturnsArray() async throws {
        let (dev, secret) = try await newSession()
        do {
            _ = try await HTTPCofService(client: makeClient())
                .listPaymentMethods(customerAccessSecret: secret, sessionId: dev.sessionId)
        } catch let error as CheckoutError {
            XCTFail("Card list with a valid secret threw code \(error.code), category \(error.category).")
        }
    }

    func testCardListWithWrongSecretIsUnauthorized() async throws {
        let (dev, _) = try await newSession()
        let wrong = "cas_" + String(repeating: "0", count: 32)
        do {
            _ = try await HTTPCofService(client: makeClient())
                .listPaymentMethods(customerAccessSecret: wrong, sessionId: dev.sessionId)
            XCTFail("Expected the card list to throw for a wrong secret.")
        } catch let error as CheckoutError {
            XCTAssertEqual(error.code, "S06", "Observed code: \(error.code)")
            XCTAssertNotEqual(error.category, .network, "Observed category: \(error.category)")
        }
    }

    /// Pays a new card with `save: true` and a host billing address, then pays the saved card on a new session.
    /// On the dev merchant this is currently expected to fail at step 1 with `PAYMENT_FAILED`
    /// ("No available channel") until the store-card channel is configured.
    func testStoreThenPayWithSavedCard() async throws {
        let card = try testCard()
        let last4 = String(card.number.filter(\.isNumber).suffix(4))

        // Step 0: list the saved cards on a fresh session before paying.
        let (baseline, baselineSecret) = try await newSession()
        let idsBefore: Set<String>
        do {
            idsBefore = Set(try await HTTPCofService(client: makeClient())
                .listPaymentMethods(customerAccessSecret: baselineSecret, sessionId: baseline.sessionId)
                .map(\.id))
        } catch let error as CheckoutError {
            return XCTFail("Step 0 (list before paying) failed with code \(error.code).")
        }

        // Step 1: pay a new card and ask the backend to store it.
        let dev1 = try await DevSessionClient(serverURL: try devServerURL())
            .createSession(collectBillingAddress: true)
        guard let firstSecret = dev1.customerAccessSecret else {
            throw XCTSkip("The dev server did not return a customerAccessSecret.")
        }
        let first = dev1
        let credentials = CredentialStore()
        let controller = makeController(credentials: credentials)
        do {
            _ = try await controller.start(sessionId: first.sessionId,
                                           customerAccessSecret: firstSecret,
                                           checkoutClientSecret: first.checkoutClientSecret)
        } catch let error as CheckoutError {
            return XCTFail("Step 1 (start first session) failed with code \(error.code).")
        }
        let storeOutcome = await controller.confirmNewCard(
            CardInput(cardNumber: card.number, expiryMonth: card.month, expiryYear: card.year, cvv: card.cvv),
            save: true,
            billingAddress: AddressInput(country: "US", line1: "1 Test St", city: "San Jose", state: "CA",
                                         postalCode: "95112", firstName: "Test", lastName: "User"))
        guard case .succeeded = storeOutcome else {
            return XCTFail("Step 1 (pay new card with save) outcome: \(describe(storeOutcome)).")
        }

        // Step 2: list on a fresh session for the same dev customer; require a NEW id with the same last4.
        let (second, secondSecret) = try await newSession()
        let saved: [SavedCard]
        do {
            saved = try await HTTPCofService(client: makeClient())
                .listPaymentMethods(customerAccessSecret: secondSecret, sessionId: second.sessionId)
        } catch let error as CheckoutError {
            return XCTFail("Step 2 (list on a new session) failed with code \(error.code).")
        }
        guard let match = saved.first(where: { !idsBefore.contains($0.id) && $0.last4 == last4 }) else {
            return XCTFail("Step 2 (list on a new session): no NEW saved card matches the test card last4; "
                           + "\(idsBefore.count) before, \(saved.count) after.")
        }

        // Step 3: pay the saved card on that second session.
        let credentials2 = CredentialStore()
        let controller2 = makeController(credentials: credentials2)
        do {
            _ = try await controller2.start(sessionId: second.sessionId,
                                            customerAccessSecret: secondSecret,
                                            checkoutClientSecret: second.checkoutClientSecret)
        } catch let error as CheckoutError {
            return XCTFail("Step 3 (start second session) failed with code \(error.code).")
        }
        let savedOutcome = await controller2.confirmSavedCard(paymentMethodId: match.id)
        guard case .succeeded = savedOutcome else {
            return XCTFail("Step 3 (pay saved card) outcome: \(describe(savedOutcome)).")
        }
    }
}
