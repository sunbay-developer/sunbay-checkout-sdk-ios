import Foundation
import SunbayCheckoutTestSupport
import XCTest

final class DevSessionClientTests: XCTestCase {
    private let serverURL = URL(string: "http://127.0.0.1:8095")!

    override func tearDown() {
        StubURLProtocol.handler = nil
        super.tearDown()
    }

    /// Reads the request body whether URLSession exposes it as `httpBody` or a stream.
    private func bodyData(of request: URLRequest) -> Data {
        if let body = request.httpBody { return body }
        guard let stream = request.httpBodyStream else { return Data() }
        stream.open()
        defer { stream.close() }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 1024)
        while stream.hasBytesAvailable {
            let count = stream.read(&buffer, maxLength: buffer.count)
            if count <= 0 { break }
            data.append(buffer, count: count)
        }
        return data
    }

    func testCreateSessionSendsAmountAndAddressFlags() async throws {
        var captured: [String: Any] = [:]
        var capturedPath = ""
        StubURLProtocol.handler = { [self] request in
            capturedPath = request.url?.path ?? ""
            captured = (try? JSONSerialization.jsonObject(with: bodyData(of: request))) as? [String: Any] ?? [:]
            let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
            let json = #"{"sessionId":"s1","checkoutClientSecret":"ccs_1","customerAccessSecret":"cas_1"}"#
            return (response, Data(json.utf8))
        }
        let client = DevSessionClient(serverURL: serverURL, session: StubURLProtocol.session())
        let session = try await client.createSession(
            amountMajorUnits: 1.05, collectBillingAddress: true, collectShippingAddress: true
        )
        XCTAssertEqual(capturedPath, "/api/create-session")
        XCTAssertEqual(captured["amount"] as? Double, 1.05)
        XCTAssertEqual(captured["collectBillingAddress"] as? Bool, true)
        XCTAssertEqual(captured["collectShippingAddress"] as? Bool, true)
        XCTAssertEqual(session.sessionId, "s1")
        XCTAssertEqual(session.checkoutClientSecret, "ccs_1")
        XCTAssertEqual(session.customerAccessSecret, "cas_1")
    }

    func testServerErrorThrowsDescriptiveError() async {
        StubURLProtocol.handler = { request in
            (HTTPURLResponse(url: request.url!, statusCode: 503, httpVersion: nil, headerFields: nil)!, Data())
        }
        let client = DevSessionClient(serverURL: serverURL, session: StubURLProtocol.session())
        do {
            _ = try await client.createSession()
            XCTFail("Expected an error")
        } catch let error as DevSessionError {
            XCTAssertTrue(error.description.contains("503"))
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }
}
