import XCTest
@testable import SunbayCheckout

final class SunbayAPIClientTests: XCTestCase {
    private struct Body: Encodable, Sendable { let a: Int }
    private struct Payload: Decodable, Sendable, Equatable { let x: Int }

    private let sessionId = "cs_secret_session_123"

    override func tearDown() {
        StubURLProtocol.handler = nil
        super.tearDown()
    }

    private func client(locale: String? = "zh-CN") -> SunbayAPIClient {
        SunbayAPIClient(environment: .dev, locale: locale, session: StubURLProtocol.session())
    }

    private func respond(_ status: Int, _ body: String, for request: URLRequest) -> (HTTPURLResponse, Data) {
        let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!
        return (response, Data(body.utf8))
    }

    private func call() async throws -> Payload {
        try await client().post(.loadSession(id: sessionId), body: Body(a: 1))
    }

    private func expectError(_ code: String, _ category: CheckoutError.Category, traceId: String? = nil,
                             file: StaticString = #filePath, line: UInt = #line) async {
        do {
            _ = try await call()
            XCTFail("expected throw", file: file, line: line)
        } catch let error as CheckoutError {
            XCTAssertEqual(error.code, code, file: file, line: line)
            XCTAssertEqual(error.category, category, file: file, line: line)
            XCTAssertEqual(error.traceId, traceId, file: file, line: line)
            XCTAssertFalse(error.message.contains(sessionId), file: file, line: line)
        } catch {
            XCTFail("non-CheckoutError thrown", file: file, line: line)
        }
    }

    func testSuccessDecodesData() async throws {
        StubURLProtocol.handler = { self.respond(200, #"{"code":"0","msg":"ok","data":{"x":1}}"#, for: $0) }
        let result = try await call()
        XCTAssertEqual(result, Payload(x: 1))
    }

    func testRequestShape() async throws {
        var captured: URLRequest?
        StubURLProtocol.handler = {
            captured = $0
            return self.respond(200, #"{"code":"0","msg":"ok","data":{"x":1}}"#, for: $0)
        }
        _ = try await call() as Payload
        XCTAssertEqual(captured?.httpMethod, "POST")
        XCTAssertEqual(captured?.value(forHTTPHeaderField: "Content-Type"), "application/json")
        XCTAssertEqual(captured?.value(forHTTPHeaderField: "Accept-Language"), "zh-CN")
        XCTAssertTrue(captured?.value(forHTTPHeaderField: "X-Sunbay-SDK")?.hasPrefix("ios/") == true)
    }

    func testEnvelopeFailure() async {
        StubURLProtocol.handler = {
            self.respond(200, #"{"code":"CHECKOUT_EXPIRED","msg":"expired","traceId":"t1"}"#, for: $0)
        }
        await expectError("CHECKOUT_EXPIRED", .payment, traceId: "t1")
    }

    func testHTTP502WithHTML() async {
        StubURLProtocol.handler = { self.respond(502, "<html>Bad Gateway</html>", for: $0) }
        await expectError("HTTP_502", .network)
    }

    func testHTTP200WithHTML() async {
        StubURLProtocol.handler = { self.respond(200, "<html>hi</html>", for: $0) }
        await expectError("INVALID_RESPONSE", .network)
    }

    func testSuccessWithoutDataIsInvalid() async {
        StubURLProtocol.handler = { self.respond(200, #"{"code":"0","msg":"ok"}"#, for: $0) }
        await expectError("INVALID_RESPONSE", .network)
    }

    func testTimeout() async {
        StubURLProtocol.handler = { _ in throw URLError(.timedOut) }
        await expectError("NETWORK_UNAVAILABLE", .network)
    }

    func testNotConnected() async {
        StubURLProtocol.handler = { _ in throw URLError(.notConnectedToInternet) }
        await expectError("NETWORK_UNAVAILABLE", .network)
    }
}
