import Foundation
import XCTest

@testable import SunbayCheckout

final class HTTPCofServiceTests: XCTestCase {
    private final class Recorder: @unchecked Sendable {
        private let lock = NSLock()
        private var bodies: [String] = []
        private var urls: [String] = []
        func record(_ request: URLRequest) {
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
            lock.lock()
            bodies.append(String(decoding: data, as: UTF8.self))
            urls.append(request.url?.absoluteString ?? "")
            lock.unlock()
        }
        var allBodies: [String] { lock.lock(); defer { lock.unlock() }; return bodies }
        var allURLs: [String] { lock.lock(); defer { lock.unlock() }; return urls }
    }

    private let recorder = Recorder()

    override func tearDown() {
        StubURLProtocol.handler = nil
        super.tearDown()
    }

    private func stub(_ json: String, status: Int = 200) {
        let recorder = self.recorder
        StubURLProtocol.handler = { request in
            recorder.record(request)
            let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!
            return (response, Data(json.utf8))
        }
    }

    private func makeService() -> HTTPCofService {
        HTTPCofService(client: SunbayAPIClient(
            environment: .dev, locale: nil, session: StubURLProtocol.session()))
    }

    private func item(
        id: String? = "sc_1", masked: String = "**** **** **** 4242", brand: String = "VISA",
        month: String = "07", year: String = "29"
    ) -> String {
        let idPart = id.map { #""savedCardId":"\#($0)","# } ?? ""
        return #"{\#(idPart)"maskedCardNumber":"\#(masked)","cardBrand":"\#(brand)","expiryMonth":"\#(month)","expiryYear":"\#(year)","cardholderName":"A B"}"#
    }

    private func envelope(cards: [String]) -> String {
        #"{"code":"0","msg":"ok","data":{"cards":[\#(cards.joined(separator: ","))]}}"#
    }

    func testRequestBodyAndPath() async throws {
        stub(envelope(cards: []))
        _ = try await makeService().listPaymentMethods(customerAccessSecret: "cas_x", sessionId: "s1")
        let parsed = try JSONSerialization.jsonObject(
            with: Data((recorder.allBodies.first ?? "").utf8)) as? [String: String]
        XCTAssertEqual(parsed, ["sessionId": "s1", "customerAccessSecret": "cas_x"])
        XCTAssertEqual(recorder.allURLs, ["https://checkout.sunbay-dev.com/api/checkout/web/card/list"])
    }

    func testMapsValidCard() async throws {
        stub(envelope(cards: [item()]))
        let cards = try await makeService().listPaymentMethods(customerAccessSecret: "cas_x", sessionId: "s1")
        XCTAssertEqual(cards, [SavedCard(id: "sc_1", brand: "visa", last4: "4242", expMonth: 7, expYear: 2029)])
    }

    func testFourDigitYearIsKept() async throws {
        stub(envelope(cards: [item(year: "2031")]))
        let cards = try await makeService().listPaymentMethods(customerAccessSecret: "cas_x", sessionId: "s1")
        XCTAssertEqual(cards.first?.expYear, 2031)
    }

    func testInvalidItemsAreDroppedAndValidSiblingSurvives() async throws {
        let bad = [
            item(masked: "****"),
            item(month: "13"),
            item(month: "ab"),
            item(year: "5"),
            item(id: nil),
        ]
        for badItem in bad {
            stub(envelope(cards: [badItem, item(id: "sc_ok")]))
            let cards = try await makeService().listPaymentMethods(customerAccessSecret: "cas_x", sessionId: "s1")
            XCTAssertEqual(cards.map(\.id), ["sc_ok"], badItem)
        }
    }

    func testEmptyDataAndEmptyCardsGiveEmptyList() async throws {
        stub(#"{"code":"0","msg":"ok","data":{}}"#)
        var cards = try await makeService().listPaymentMethods(customerAccessSecret: "cas_x", sessionId: "s1")
        XCTAssertEqual(cards, [])
        stub(#"{"code":"0","msg":"ok","data":{"cards":[]}}"#)
        cards = try await makeService().listPaymentMethods(customerAccessSecret: "cas_x", sessionId: "s1")
        XCTAssertEqual(cards, [])
    }

    func testUnauthorizedThrowsAndLeaksNoSecret() async {
        stub(#"{"code":"S06","msg":"Unauthorized"}"#)
        do {
            _ = try await makeService().listPaymentMethods(customerAccessSecret: "cas_x", sessionId: "s1")
            XCTFail("expected throw")
        } catch let error as CheckoutError {
            XCTAssertEqual(error.code, "S06")
            XCTAssertFalse(error.message.contains("cas_x"))
            XCTAssertFalse(error.message.contains("customerAccessSecret"))
            XCTAssertFalse("\(error)".contains("cas_x"))
        } catch {
            XCTFail("unexpected error \(error)")
        }
    }
}
