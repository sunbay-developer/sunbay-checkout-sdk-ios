import XCTest

@testable import SunbayCheckout

final class ContractCodableTests: XCTestCase {
    func test_decodeSession_mapsAmountMethodsAndFlags() throws {
        let json = """
            {
              "sessionId": "sess_abc123",
              "sessionType": "EMBED",
              "currency": "USD",
              "totalAmount": 1299,
              "description": "Order #42",
              "expiresAt": "2026-10-26T12:30:00Z",
              "paymentMethods": [
                { "method": "VISA", "type": "CARD", "name": "Visa" },
                { "method": "APPLE_PAY", "type": "E_WALLET", "name": "Apple Pay" },
                { "method": "GOOGLE_PAY", "type": "E_WALLET", "name": "Google Pay" }
              ],
              "merchantName": "Acme Store",
              "rsaPublicKey": "MIIBIjANBgkqh-base64-key",
              "cofEnabled": true
            }
            """

        let session = try ContractDecoding.decodeSession(from: Data(json.utf8))

        XCTAssertEqual(session.id, "sess_abc123")
        XCTAssertEqual(session.amount.minorUnits, 1299)
        XCTAssertEqual(session.amount.currencyCode, "USD")
        XCTAssertEqual(session.merchantName, "Acme Store")
        XCTAssertEqual(session.rsaPublicKey, "MIIBIjANBgkqh-base64-key")
        XCTAssertTrue(session.cofEnabled)
        // VISA/CARD -> .card, APPLE_PAY -> .applePay; GOOGLE_PAY unknown -> ignored.
        XCTAssertTrue(session.methods.contains(.card))
        XCTAssertTrue(session.methods.contains(.applePay))
        XCTAssertFalse(session.methods.contains(.savedCard))
        XCTAssertEqual(session.methods.count, 2)
    }

    func test_decodeResult_requiresAction_redirect() throws {
        let json = """
            {
              "txnId": "txn_777",
              "txnStatus": "R",
              "sessionId": "sess_abc123",
              "totalAmount": 1299,
              "currency": "USD",
              "action": {
                "type": "redirect",
                "redirectUrl": "https://psp.example.com/3ds?token=xyz"
              }
            }
            """

        let envelope = try ContractDecoding.decodeResult(from: Data(json.utf8))

        XCTAssertEqual(
            envelope.snapshot,
            PaymentSnapshot(sessionId: "sess_abc123", status: .requiresAction, txnId: "txn_777")
        )
        XCTAssertEqual(
            envelope.action,
            .redirect(url: URL(string: "https://psp.example.com/3ds?token=xyz")!)
        )
    }

    func test_decodeResult_requiresAction_qrCode() throws {
        let json = """
            {
              "txnId": "txn_888",
              "txnStatus": "R",
              "sessionId": "sess_abc123",
              "totalAmount": 1299,
              "currency": "USD",
              "action": {
                "type": "qrCode",
                "qrData": { "qrCode": "data", "qrUrl": "https://psp.example.com/qr" }
              }
            }
            """

        let envelope = try ContractDecoding.decodeResult(from: Data(json.utf8))

        XCTAssertEqual(envelope.snapshot.status, .requiresAction)
        XCTAssertEqual(envelope.action, .qrCode)
    }
}
