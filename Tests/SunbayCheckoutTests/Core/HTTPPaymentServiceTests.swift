import XCTest
@testable import SunbayCheckout

final class HTTPPaymentServiceTests: XCTestCase {
    private var captured: [URLRequest] = []
    private var bodies: [[String: Any]] = []

    override func setUp() {
        super.setUp()
        captured = []
        bodies = []
    }

    override func tearDown() {
        StubURLProtocol.handler = nil
        super.tearDown()
    }

    private func makeService(secret: String? = "ccs_x") async -> HTTPPaymentService {
        let credentials = CredentialStore()
        if let secret { await credentials.hold(checkoutClientSecret: secret) }
        let client = SunbayAPIClient(environment: .dev, locale: nil, session: StubURLProtocol.session())
        return HTTPPaymentService(
            client: client, credentials: credentials,
            deviceInfo: { DeviceInfoCollector.collect(screen: (width: 390, height: 844, scale: 3)) })
    }

    private func readBody(_ request: URLRequest) -> [String: Any] {
        var data = request.httpBody ?? Data()
        if data.isEmpty, let stream = request.httpBodyStream {
            stream.open()
            defer { stream.close() }
            var buffer = [UInt8](repeating: 0, count: 4096)
            while stream.hasBytesAvailable {
                let n = stream.read(&buffer, maxLength: buffer.count)
                if n <= 0 { break }
                data.append(buffer, count: n)
            }
        }
        return (try? JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? [:]
    }

    private func stub(_ responses: [String]) {
        var queue = responses
        StubURLProtocol.handler = { request in
            self.captured.append(request)
            self.bodies.append(self.readBody(request))
            let body = queue.isEmpty ? "{}" : queue.removeFirst()
            let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
            return (response, Data(body.utf8))
        }
    }

    private let sessionJSON = #"""
    {"code":"0","msg":"ok","data":{"sessionId":"s1","sessionType":"sdk","currency":"USD","totalAmount":1000,
    "expiresAt":"2030-01-01T00:00:00Z","merchantName":"M","supportStoreCard":false,
    "paymentMethods":[{"method":"VISA","type":"CARD"}]}}
    """#

    private func result(_ status: String, extra: String = "") -> String {
        #"{"code":"0","msg":"ok","data":{"txnId":"t1","txnStatus":"\#(status)","sessionId":"s1"\#(extra)}}"#
    }

    func testLoadSessionSendsSecretAndDecodes() async throws {
        stub([sessionJSON])
        let service = await makeService()
        let session = try await service.loadSession("s1")
        XCTAssertEqual(captured.first?.url?.path, "/api/checkout/web/session/s1")
        XCTAssertEqual(bodies.first as? [String: String], ["checkoutClientSecret": "ccs_x"])
        XCTAssertEqual(session.id, "s1")
        XCTAssertEqual(session.sessionType, "sdk")
        XCTAssertFalse(session.cofEnabled)
    }

    func testLoadSessionWithoutSecretThrowsConfigurationAndSendsNothing() async {
        stub([sessionJSON])
        let service = await makeService(secret: nil)
        do {
            _ = try await service.loadSession("s1")
            XCTFail("expected throw")
        } catch let error as CheckoutError {
            XCTAssertEqual(error.code, "CHECKOUT_CLIENT_SECRET_MISSING")
            XCTAssertEqual(error.category, .configuration)
        } catch {
            XCTFail("wrong error")
        }
        XCTAssertTrue(captured.isEmpty)
    }

    func testLoadSessionBadBodyIsNetworkInvalidResponse() async {
        stub([#"{"code":"0","msg":"ok","data":{"sessionId":"s1","currency":"USD","totalAmount":1,"expiresAt":"nope","merchantName":"M","paymentMethods":[]}}"#])
        let service = await makeService()
        do {
            _ = try await service.loadSession("s1")
            XCTFail("expected throw")
        } catch let error as CheckoutError {
            XCTAssertEqual(error.code, "INVALID_RESPONSE")
            XCTAssertEqual(error.category, .network)
        } catch {
            XCTFail("wrong error")
        }
    }

    func testNewCardSubmitBody() async throws {
        stub([result("S")])
        let service = await makeService()
        let snapshot = try await service.submit(SubmitRequest(
            sessionId: "s1", paymentMethod: "CARD", attemptId: UUID(),
            cardEncryptedData: "CIPHER", storeCard: true, checkoutClientSecret: "ccs_x",
            sessionType: "sdk"))
        XCTAssertEqual(captured.first?.url?.path, "/api/checkout/web/payment/submit")
        let body = bodies[0]
        XCTAssertEqual(body["sessionId"] as? String, "s1")
        XCTAssertEqual(body["paymentMethod"] as? String, "CARD")
        XCTAssertEqual(body["sessionType"] as? String, "sdk")
        XCTAssertEqual(body["cardEncryptedData"] as? String, "CIPHER")
        XCTAssertEqual(body["checkoutClientSecret"] as? String, "ccs_x")
        XCTAssertEqual(body["storeCard"] as? Bool, true)
        XCTAssertNotNil(body["userDeviceInfo"] as? [String: Any])
        XCTAssertNil(body["savedCardId"])
        XCTAssertNil(body["customerAccessSecret"])
        XCTAssertEqual(snapshot.status, .succeeded)
        XCTAssertEqual(snapshot.txnId, "t1")
    }

    func testSavedCardSubmitBody() async throws {
        stub([result("S")])
        let service = await makeService()
        _ = try await service.submit(SubmitRequest(
            sessionId: "s1", paymentMethod: "TOKEN", attemptId: UUID(),
            savedCardId: "card_1", customerAccessSecret: "cas_1", checkoutClientSecret: "ccs_x"))
        let body = bodies[0]
        XCTAssertEqual(body["paymentMethod"] as? String, "TOKEN")
        XCTAssertEqual(body["savedCardId"] as? String, "card_1")
        XCTAssertEqual(body["customerAccessSecret"] as? String, "cas_1")
        XCTAssertNil(body["cardEncryptedData"])
    }

    func testApplePaySubmitBodyCarriesTokenJSONString() async throws {
        stub([result("S")])
        let service = await makeService()
        let token = #"{"paymentData":{"version":"EC_v1"}}"#
        _ = try await service.submit(SubmitRequest(
            sessionId: "s1", paymentMethod: "APPLE_PAY", attemptId: UUID(),
            walletToken: Data(token.utf8), checkoutClientSecret: "ccs_x"))
        XCTAssertEqual(bodies[0]["paymentMethod"] as? String, "APPLE_PAY")
        XCTAssertEqual(bodies[0]["cardEncryptedData"] as? String, token)
    }

    func testRequiresActionRedirectThenStaleActionCleared() async throws {
        stub([
            result("R", extra: #","action":{"type":"redirect","redirectUrl":"https://example.com/3ds"}"#),
            result("S"),
        ])
        let service = await makeService()
        let request = SubmitRequest(sessionId: "s1", paymentMethod: "CARD", attemptId: UUID(),
                                    cardEncryptedData: "C", checkoutClientSecret: "ccs_x")
        let first = try await service.submit(request)
        XCTAssertEqual(first.status, .requiresAction)
        XCTAssertEqual(service.actionForLatestRequiresAction(), .redirect(url: URL(string: "https://example.com/3ds")!))
        let second = try await service.submit(request)
        XCTAssertEqual(second.status, .succeeded)
        XCTAssertNil(service.actionForLatestRequiresAction())
    }

    func testGetResultPostsEmptyObject() async throws {
        stub([result("S")])
        let service = await makeService()
        let snapshot = try await service.getResult(sessionId: "s1")
        XCTAssertEqual(captured.first?.url?.path, "/api/checkout/web/payment/result/s1")
        XCTAssertTrue(bodies[0].isEmpty)
        XCTAssertEqual(snapshot.status, .succeeded)
    }

    func testGetResultWithoutWireSessionIdFallsBackToQueriedSession() async throws {
        stub([#"{"code":"0","msg":"Success","data":{"txnId":"t9","txnStatus":"S","totalAmount":"1.13","currency":"USD","failureReason":"success"}}"#])
        let service = await makeService()
        let snapshot = try await service.getResult(sessionId: "s1")
        XCTAssertEqual(snapshot.status, .succeeded)
        XCTAssertEqual(snapshot.txnId, "t9")
        XCTAssertEqual(snapshot.sessionId, "s1")
    }

    func testGetResultFailedWithoutWireSessionId() async throws {
        stub([#"{"code":"0","msg":"Success","data":{"txnId":"t9","txnStatus":"F","totalAmount":"1.13","currency":"USD","failureReason":"No available channel"}}"#])
        let service = await makeService()
        let snapshot = try await service.getResult(sessionId: "s1")
        XCTAssertEqual(snapshot.status, .failed)
        XCTAssertEqual(snapshot.sessionId, "s1")
    }

    func testUnknownTxnStatusIsNetworkInvalidResponse() async {
        stub([result("Z")])
        let service = await makeService()
        do {
            _ = try await service.getResult(sessionId: "s1")
            XCTFail("expected throw")
        } catch let error as CheckoutError {
            XCTAssertEqual(error.code, "INVALID_RESPONSE")
            XCTAssertEqual(error.category, .network)
        } catch {
            XCTFail("wrong error")
        }
    }
}
