import Foundation
import XCTest
@testable import SunbayCheckout
import SunbayCheckoutTestSupport

/// Opt-in address checks against the real dev backend. They skip unless `SUNBAY_DEV_SERVER_URL` is
/// set (the card-based check also needs `SUNBAY_TEST_CARD_*`). Card values and addresses are never
/// logged; messages name only the outcome case and the error code.
final class RealAPIAddressTests: XCTestCase {
    private let environment: CheckoutConfiguration.Environment = .dev

    private struct NoopActionHandler: ActionHandling {
        func handle(_ action: PaymentAction, sessionId: String) async -> ActionResult { .pending }
    }

    private func devServerURL() throws -> URL {
        let raw = ProcessInfo.processInfo.environment["SUNBAY_DEV_SERVER_URL"]
        try XCTSkipIf(raw == nil || raw?.isEmpty == true, "SUNBAY_DEV_SERVER_URL is not set.")
        guard let raw, let url = URL(string: raw) else {
            throw XCTSkip("SUNBAY_DEV_SERVER_URL is not a valid URL.")
        }
        return url
    }

    private func makeClient() -> SunbayAPIClient {
        SunbayAPIClient(environment: environment, locale: "en-US")
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

    // (a) Address metadata: countries and the US config.
    func testAddressMetadataCountriesAndUSConfig() async throws {
        _ = try devServerURL()
        let service = HTTPAddressMetadataService(client: makeClient())
        do {
            let list = try await service.countries(locale: "en-US")
            XCTAssertGreaterThanOrEqual(list.countries.count, 1, "Observed countries: \(list.countries.count)")
            let config = try await service.countryConfig(countryCode: "US", locale: "en-US")
            XCTAssertNotNil(config.fields[.state], "The US config has no state field.")
            XCTAssertGreaterThanOrEqual(config.subdivisions.count, 50,
                                        "Observed US subdivisions: \(config.subdivisions.count)")
        } catch let error as CheckoutError {
            XCTFail("Address metadata failed with code \(error.code), category \(error.category).")
        }
    }

    // (b) New-card submit with save and a host billing address must not fail with C01.
    func testNewCardWithHostBillingAddressIsNotC01() async throws {
        let serverURL = try devServerURL()
        let env = ProcessInfo.processInfo.environment
        guard let number = env["SUNBAY_TEST_CARD_NUMBER"], let month = env["SUNBAY_TEST_CARD_EXPIRY_MM"],
              let year = env["SUNBAY_TEST_CARD_EXPIRY_YYYY"], let cvv = env["SUNBAY_TEST_CARD_CVV"] else {
            throw XCTSkip("SUNBAY_TEST_CARD_* environment variables are not set.")
        }
        let dev = try await DevSessionClient(serverURL: serverURL)
            .createSession(collectBillingAddress: true)
        guard let secret = dev.customerAccessSecret else {
            throw XCTSkip("The dev server did not return a customerAccessSecret.")
        }
        let credentials = CredentialStore()
        let controller = CheckoutController(
            paymentService: HTTPPaymentService(client: makeClient(), credentials: credentials, deviceInfo: { nil }),
            cofService: HTTPCofService(client: makeClient()),
            credentials: credentials,
            actionHandler: NoopActionHandler(),
            cardOnFile: CardOnFileOptions())
        do {
            _ = try await controller.start(sessionId: dev.sessionId,
                                           customerAccessSecret: secret,
                                           checkoutClientSecret: dev.checkoutClientSecret)
        } catch let error as CheckoutError {
            return XCTFail("Start failed with code \(error.code).")
        }
        let billing = AddressInput(country: "US", line1: "1 Test St", city: "San Jose", state: "CA",
                                   postalCode: "95112", firstName: "Test", lastName: "User")
        let outcome = await controller.confirmNewCard(
            CardInput(cardNumber: number, expiryMonth: month, expiryYear: year, cvv: cvv),
            save: true,
            billingAddress: billing)
        // Diagnostic only: outcome case and error code, never card or address values.
        print("RealAPIAddressTests outcome: \(describe(outcome))")
        if case .failed(_, let error) = outcome {
            XCTAssertNotEqual(error.code, "C01", "Observed outcome: \(describe(outcome))")
        }
    }
}
