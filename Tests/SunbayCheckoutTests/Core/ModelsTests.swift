import XCTest

@testable import SunbayCheckout

final class ModelsTests: XCTestCase {
    func test_txnStatus_rawValues() {
        XCTAssertEqual(TxnStatus(rawValue: "I"), .initial)
        XCTAssertEqual(TxnStatus(rawValue: "S"), .succeeded)
        XCTAssertEqual(TxnStatus(rawValue: "F"), .failed)
        XCTAssertEqual(TxnStatus(rawValue: "R"), .requiresAction)
    }

    func test_amount_equatable() {
        XCTAssertEqual(
            Amount(minorUnits: 999, currencyCode: "USD"),
            Amount(minorUnits: 999, currencyCode: "USD")
        )
    }

    func test_checkoutOutcome_failed_carriesErrorCodeAndCategory() {
        let error = CheckoutError(
            code: "CARD_DECLINED",
            message: "The card was declined.",
            category: .payment,
            traceId: "trace-123"
        )
        let outcome = CheckoutOutcome.failed(txnId: "txn-1", error: error)

        guard case let .failed(txnId, resultError) = outcome else {
            return XCTFail("Expected .failed outcome")
        }
        XCTAssertEqual(txnId, "txn-1")
        XCTAssertEqual(resultError.code, "CARD_DECLINED")
        XCTAssertEqual(resultError.category, .payment)
        XCTAssertEqual(resultError.traceId, "trace-123")
    }
}
