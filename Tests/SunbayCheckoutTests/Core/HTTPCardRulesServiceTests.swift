import XCTest
@testable import SunbayCheckout

final class HTTPCardRulesServiceTests: XCTestCase {
    private var requests: [URLRequest] = []

    override func setUp() {
        super.setUp()
        requests = []
    }

    override func tearDown() {
        StubURLProtocol.handler = nil
        super.tearDown()
    }

    private func service() -> HTTPCardRulesService {
        HTTPCardRulesService(
            client: SunbayAPIClient(environment: .dev, locale: nil, session: StubURLProtocol.session()))
    }

    private func stub(_ body: String, status: Int = 200, headers: [String: String]? = nil) {
        StubURLProtocol.handler = { request in
            self.requests.append(request)
            let response = HTTPURLResponse(
                url: request.url!, statusCode: status, httpVersion: nil, headerFields: headers)!
            return (response, Data(body.utf8))
        }
    }

    func testFetchWithoutETagSendsNoIfNoneMatch() async throws {
        stub("{}")
        _ = try await service().fetchRules(ifNoneMatch: nil)
        XCTAssertEqual(requests.count, 1)
        XCTAssertEqual(requests[0].url?.absoluteString, "https://checkout.sunbay-dev.com/api/card/rules")
        XCTAssertEqual(requests[0].httpMethod, "GET")
        XCTAssertNil(requests[0].value(forHTTPHeaderField: "If-None-Match"))
    }

    func testFetchSendsStoredETagVerbatim() async throws {
        stub("{}")
        _ = try await service().fetchRules(ifNoneMatch: "\"abc123\"")
        XCTAssertEqual(requests[0].value(forHTTPHeaderField: "If-None-Match"), "\"abc123\"")
    }

    func test200ReturnsBodyBytesAndETagHeader() async throws {
        let body = "{\"schemaVersion\":1}"
        stub(body, headers: ["ETag": "\"abc123\""])
        let result = try await service().fetchRules(ifNoneMatch: nil)
        guard case let .updated(data, etag) = result else { return XCTFail("expected .updated") }
        XCTAssertEqual(data, Data(body.utf8))
        XCTAssertEqual(etag, "\"abc123\"")
    }

    func test200WithoutETagHeaderReturnsNilETag() async throws {
        stub("{}")
        let result = try await service().fetchRules(ifNoneMatch: nil)
        guard case let .updated(_, etag) = result else { return XCTFail("expected .updated") }
        XCTAssertNil(etag)
    }

    func test304ReturnsNotModified() async throws {
        stub("", status: 304)
        let result = try await service().fetchRules(ifNoneMatch: "\"x\"")
        guard case .notModified = result else { return XCTFail("expected .notModified") }
    }

    func testOtherStatusesThrow() async {
        for status in [404, 429, 500] {
            stub("{\"code\":\"E\",\"msg\":\"nope\",\"data\":null}", status: status)
            do {
                _ = try await service().fetchRules(ifNoneMatch: nil)
                XCTFail("status \(status) should throw")
            } catch let error as CheckoutError {
                XCTAssertEqual(error.code, "HTTP_\(status)")
                XCTAssertFalse(error.message.contains("nope"))
            } catch {
                XCTFail("unexpected error \(error)")
            }
        }
    }

    func testTransportFailureThrowsAndIsNotRetried() async {
        var calls = 0
        StubURLProtocol.handler = { request in
            calls += 1
            self.requests.append(request)
            throw URLError(.notConnectedToInternet)
        }
        do {
            _ = try await service().fetchRules(ifNoneMatch: nil)
            XCTFail("should throw")
        } catch {}
        XCTAssertEqual(calls, 1)
        XCTAssertEqual(requests.first?.timeoutInterval, 3)
    }
}
