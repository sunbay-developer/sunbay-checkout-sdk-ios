import XCTest
import SunbayCheckout
@testable import Showcase

final class ShowcaseServicesTests: XCTestCase {
    private func makeRequest(_ sessionId: String) -> SubmitRequest {
        SubmitRequest(sessionId: sessionId, paymentMethod: "applepay", attemptId: UUID())
    }

    func testLoadSessionReflectsAmountCurrencyAndMethods() async throws {
        let service = ShowcasePaymentService(amountMinor: 12_345, sessionId: "sess_1")
        let session = try await service.loadSession("sess_1")
        XCTAssertEqual(session.id, "sess_1")
        XCTAssertEqual(session.amount, Amount(minorUnits: 12_345, currencyCode: "USD"))
        XCTAssertEqual(session.methods, [.card, .applePay, .savedCard])
        XCTAssertTrue(session.cofEnabled)
        XCTAssertEqual(session.rsaPublicKey, ShowcaseRSAKey.publicKeyBase64)
    }

    func testSubmitSucceedsWithGeneratedTxnId() async throws {
        let service = ShowcasePaymentService(amountMinor: 100, sessionId: "sess_2")
        let snapshot = try await service.submit(makeRequest("sess_2"))
        XCTAssertEqual(snapshot.status, .succeeded)
        XCTAssertEqual(snapshot.sessionId, "sess_2")
        let txnId = try XCTUnwrap(snapshot.txnId)
        XCTAssertTrue(txnId.hasPrefix("txn_"))
        XCTAssertEqual(txnId.count, 12)
    }

    func testCancelledSubmitThrowsInsteadOfSucceeding() async {
        let service = ShowcasePaymentService(amountMinor: 100, sessionId: "sess_c")
        let request = makeRequest("sess_c")
        let task = Task { try await service.submit(request) }
        task.cancel()
        do {
            _ = try await task.value
            XCTFail("Cancelled submit must throw, not return a snapshot")
        } catch {
            XCTAssertTrue(error is CancellationError, "Unexpected error: \(error)")
        }
    }

    func testGetResultReturnsSameTxnIdAsSubmit() async throws {
        let service = ShowcasePaymentService(amountMinor: 100, sessionId: "sess_3")
        let submitted = try await service.submit(makeRequest("sess_3"))
        let fetched = try await service.getResult(sessionId: "sess_3")
        XCTAssertEqual(fetched.txnId, submitted.txnId)
        XCTAssertEqual(fetched.status, .succeeded)
    }

    func testCofReturnsTwoSavedCards() async throws {
        let cards = try await ShowcaseCofService().listPaymentMethods(
            customerAccessSecret: "secret", sessionId: "sess_4"
        )
        XCTAssertEqual(cards.map(\.id), ["pm_demo_visa", "pm_demo_mc"])
        XCTAssertEqual(cards.map(\.last4), ["4242", "4444"])
    }
}
