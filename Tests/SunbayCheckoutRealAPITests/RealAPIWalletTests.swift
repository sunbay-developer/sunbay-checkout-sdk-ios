import Foundation
import XCTest
@testable import SunbayCheckout
import SunbayCheckoutTestSupport

#if canImport(PassKit)
    import PassKit
#endif

/// Opt-in wallet and payment-method-filter checks against the real dev backend. They skip unless
/// `SUNBAY_DEV_SERVER_URL` is set (the card-based check also needs `SUNBAY_TEST_CARD_*`). Card values,
/// addresses and tokens are never logged; messages name only counts, outcome cases and error codes.
final class RealAPIWalletTests: XCTestCase {
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

    private func loadLiveSession() async throws -> CheckoutSession {
        let url = try devServerURL()
        let dev = try await DevSessionClient(serverURL: url).createSession()
        let credentials = CredentialStore()
        await credentials.hold(checkoutClientSecret: dev.checkoutClientSecret)
        let service = HTTPPaymentService(client: makeClient(), credentials: credentials, deviceInfo: { nil })
        return try await service.loadSession(dev.sessionId)
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

    // (a) The live APPLE_PAY entry carries usable Apple Pay request parameters.
    #if canImport(PassKit)
        func testLiveApplePayParamsMapToARequest() async throws {
            let session = try await loadLiveSession()
            guard let params = session.applePayParams else {
                return XCTFail("The live session has no readable Apple Pay parameters.")
            }
            XCTAssertFalse(params.supportedNetworks.isEmpty, "Observed networks: \(params.supportedNetworks.count)")
            XCTAssertFalse(params.merchantCapabilities.isEmpty,
                           "Observed capabilities: \(params.merchantCapabilities.count)")
            XCTAssertGreaterThanOrEqual(WalletAuthorizer.networks(from: params.supportedNetworks).count, 1)
            XCTAssertTrue(WalletAuthorizer.capabilities(from: params.merchantCapabilities).contains(.threeDSecure))
            let request = WalletAuthorizer.makeRequest(
                amount: session.amount, merchantId: "merchant.example.test",
                merchantName: session.merchantName, params: params,
                contacts: WalletContactRequest(billing: false, shipping: false))
            XCTAssertEqual(request.countryCode, "US")
        }
    #endif

    // (b) The live method entries include card entries and Apple Pay; hiding CARD keeps Apple Pay.
    func testLiveMethodEntriesAndHideCard() async throws {
        let session = try await loadLiveSession()
        let entries = session.methodEntries
        XCTAssertTrue(entries.contains { $0.type == "CARD" }, "Observed entries: \(entries.count)")
        XCTAssertTrue(entries.contains { $0.method == "APPLE_PAY" }, "Observed entries: \(entries.count)")

        let result = PaymentMethodModel.apply(PaymentMethodFilter(hide: [.card]), to: entries)
        XCTAssertFalse(result.entries.contains { $0.type == "CARD" })
        XCTAssertTrue(result.entries.contains { $0.method == "APPLE_PAY" })
        XCTAssertTrue(result.ignored.isEmpty, "Observed ignored identifiers: \(result.ignored.count)")
    }

    // (c) A new-card submit with a complete host billing address must not fail with C01.
    func testNewCardWithHostBillingAddressIsNotC01() async throws {
        let serverURL = try devServerURL()
        let env = ProcessInfo.processInfo.environment
        guard let number = env["SUNBAY_TEST_CARD_NUMBER"], let month = env["SUNBAY_TEST_CARD_EXPIRY_MM"],
              let year = env["SUNBAY_TEST_CARD_EXPIRY_YYYY"], let cvv = env["SUNBAY_TEST_CARD_CVV"] else {
            throw XCTSkip("SUNBAY_TEST_CARD_* environment variables are not set.")
        }
        let dev = try await DevSessionClient(serverURL: serverURL)
            .createSession(collectBillingAddress: true)
        let credentials = CredentialStore()
        let controller = CheckoutController(
            paymentService: HTTPPaymentService(client: makeClient(), credentials: credentials, deviceInfo: { nil }),
            cofService: HTTPCofService(client: makeClient()),
            credentials: credentials,
            actionHandler: NoopActionHandler(),
            cardOnFile: CardOnFileOptions())
        let billing = AddressInput(country: "US", line1: "1 Test St", city: "San Jose", state: "CA",
                                   postalCode: "95112", firstName: "Test", lastName: "User")
        do {
            _ = try await controller.start(sessionId: dev.sessionId,
                                           customerAccessSecret: dev.customerAccessSecret,
                                           checkoutClientSecret: dev.checkoutClientSecret,
                                           billingAddress: billing)
        } catch let error as CheckoutError {
            return XCTFail("Start failed with code \(error.code).")
        }
        let outcome = await controller.confirmNewCard(
            CardInput(cardNumber: number, expiryMonth: month, expiryYear: year, cvv: cvv), save: false)
        // Diagnostic only: outcome case and error code, never card or address values.
        print("RealAPIWalletTests outcome: \(describe(outcome))")
        if case .failed(_, let error) = outcome {
            XCTAssertNotEqual(error.code, "C01", "Observed outcome: \(describe(outcome))")
        }
    }
}
