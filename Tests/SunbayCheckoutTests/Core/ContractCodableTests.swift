import XCTest

@testable import SunbayCheckout

final class ContractCodableTests: XCTestCase {
    func test_decodeSession_mapsAmountMethodsAndFlags() throws {
        let json = """
            {
              "sessionId": "sess_abc123",
              "sessionType": "EMBED",
              "currency": "USD",
              "totalAmount": "12.99",
              "description": "Order #42",
              "expiresAt": "2026-10-26T12:30:00Z",
              "paymentMethods": [
                { "method": "VISA", "type": "CARD", "name": "Visa" },
                { "method": "APPLE_PAY", "type": "E_WALLET", "name": "Apple Pay" },
                { "method": "GOOGLE_PAY", "type": "E_WALLET", "name": "Google Pay" }
              ],
              "merchantName": "Acme Store",
              "rsaPublicKey": "MIIBIjANBgkqh-base64-key",
              "supportStoreCard": true
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

    // MARK: - Real contract session

    private func sessionJSON(
        expiresAt: String = "2026-11-09T10:00:00+08:00",
        totalAmount: String = #""10.50""#,
        currency: String = "USD",
        extra: String = "",
        methods: String = #"[{"method":"VISA","type":"CARD"}]"#,
        rsa: String = #""rsaPublicKey": "key","#
    ) -> Data {
        Data(
            """
            {
              "sessionId": "sess_1",
              "currency": "\(currency)",
              "totalAmount": \(totalAmount),
              "expiresAt": "\(expiresAt)",
              "merchantName": "Acme",
              \(rsa)
              \(extra)
              "paymentMethods": \(methods)
            }
            """.utf8)
    }

    func test_decodeSession_supportStoreCardFalse_disablesCof() throws {
        let session = try ContractDecoding.decodeSession(
            from: sessionJSON(extra: #""supportStoreCard": false,"#))
        XCTAssertFalse(session.cofEnabled)
    }

    func test_decodeSession_supportStoreCardAbsent_defaultsToTrue() throws {
        let session = try ContractDecoding.decodeSession(from: sessionJSON())
        XCTAssertTrue(session.cofEnabled)
    }

    func test_decodeSession_expiresAtOffsetVariants_parseToSameInstant() throws {
        let colon = try ContractDecoding.decodeSession(
            from: sessionJSON(expiresAt: "2026-11-09T10:00:00+08:00")).expiresAt
        let noColon = try ContractDecoding.decodeSession(
            from: sessionJSON(expiresAt: "2026-11-09T10:00:00+0800")).expiresAt
        let fractional = try ContractDecoding.decodeSession(
            from: sessionJSON(expiresAt: "2026-11-09T10:00:00.123+08:00")).expiresAt
        XCTAssertEqual(colon.timeIntervalSince1970, noColon.timeIntervalSince1970, accuracy: 0.001)
        XCTAssertEqual(
            fractional.timeIntervalSince1970 - colon.timeIntervalSince1970, 0.123, accuracy: 0.001)
    }

    func test_decodeSession_fractionalNoColonOffset_parses() throws {
        let base = try ContractDecoding.decodeSession(
            from: sessionJSON(expiresAt: "2026-11-09T10:00:00+0800")).expiresAt
        let frac = try ContractDecoding.decodeSession(
            from: sessionJSON(expiresAt: "2026-11-09T10:00:00.123+0800")).expiresAt
        XCTAssertEqual(
            frac.timeIntervalSince1970 - base.timeIntervalSince1970, 0.123, accuracy: 0.001)
    }

    private func minorUnits(_ total: String, _ currency: String) throws -> Int64 {
        try ContractDecoding.decodeSession(
            from: sessionJSON(totalAmount: total, currency: currency)).amount.minorUnits
    }

    private func assertTotalAmountRejected(
        _ total: String, _ currency: String, file: StaticString = #filePath, line: UInt = #line
    ) {
        XCTAssertThrowsError(
            try ContractDecoding.decodeSession(from: sessionJSON(totalAmount: total, currency: currency)),
            "\(total) \(currency)", file: file, line: line
        ) { error in
            guard case DecodingError.dataCorrupted(let ctx) = error else {
                return XCTFail("Expected dataCorrupted, got \(error)", file: file, line: line)
            }
            XCTAssertEqual(ctx.codingPath.last?.stringValue, "totalAmount", file: file, line: line)
        }
    }

    func test_decodeSession_majorUnitString_usd() throws {
        XCTAssertEqual(try minorUnits(#""1.13""#, "USD"), 113)
        XCTAssertEqual(try minorUnits(#""0.07""#, "USD"), 7)
        XCTAssertEqual(try minorUnits(#""19.99""#, "USD"), 1999)
        XCTAssertEqual(try minorUnits(#""10.5""#, "USD"), 1050)
        XCTAssertEqual(try minorUnits(#""0""#, "USD"), 0)
    }

    func test_decodeSession_majorUnitNumber_usd() throws {
        XCTAssertEqual(try minorUnits("1.13", "USD"), 113)
        XCTAssertEqual(try minorUnits("19.99", "USD"), 1999)
    }

    func test_decodeSession_zeroAndThreeDigitCurrencies() throws {
        XCTAssertEqual(try minorUnits(#""100""#, "JPY"), 100)
        XCTAssertEqual(try minorUnits(#""1.500""#, "KWD"), 1500)
    }

    func test_decodeSession_totalAmountCurrencyIsPreserved() throws {
        let session = try ContractDecoding.decodeSession(
            from: sessionJSON(totalAmount: #""1.13""#))
        XCTAssertEqual(session.amount, Amount(minorUnits: 113, currencyCode: "USD"))
    }

    func test_decodeSession_invalidTotalAmount_throwsDataCorrupted() {
        assertTotalAmountRejected(#""1.135""#, "USD")
        assertTotalAmountRejected(#""1.5""#, "JPY")
        assertTotalAmountRejected(#""-1.00""#, "USD")
        assertTotalAmountRejected(#""abc""#, "USD")
        assertTotalAmountRejected(#""""#, "USD")
        assertTotalAmountRejected("-1.00", "USD")
        assertTotalAmountRejected(#""99999999999999999999""#, "USD")
    }

    func test_decodeSession_legacyStoreCardKey_isIgnored() throws {
        let session = try ContractDecoding.decodeSession(
            from: sessionJSON(extra: #""storeCard": false,"#))
        XCTAssertTrue(session.cofEnabled)
    }

    func test_decodeSession_onlyUnknownMethods_yieldsEmptySet() throws {
        let session = try ContractDecoding.decodeSession(
            from: sessionJSON(methods: #"[{"method":"MYSTERY","type":"APM"}]"#))
        XCTAssertTrue(session.methods.isEmpty)
    }

    func test_decodeSession_nullRsaPublicKey_isNil() throws {
        let session = try ContractDecoding.decodeSession(
            from: sessionJSON(rsa: #""rsaPublicKey": null,"#))
        XCTAssertNil(session.rsaPublicKey)
    }

    func test_decodeResult_unknownTxnStatus_throws() {
        let json = #"{"txnStatus":"Z","sessionId":"sess_1"}"#
        XCTAssertThrowsError(try ContractDecoding.decodeResult(from: Data(json.utf8)))
    }

    func test_decodeResult_redirectWithoutOptionalFields_mapsRedirect() throws {
        let json = """
            {"txnStatus":"R","sessionId":"sess_1",
             "action":{"type":"redirect","redirectUrl":"https://x.test/p"}}
            """
        let envelope = try ContractDecoding.decodeResult(from: Data(json.utf8))
        XCTAssertEqual(envelope.action, .redirect(url: URL(string: "https://x.test/p")!))
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
