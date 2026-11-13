import Foundation
import XCTest

@testable import SunbayCheckout

/// Tests for the default (real-backend) wiring of `SunbayCheckout(configuration:)`.
final class SunbayCheckoutDefaultWiringTests: XCTestCase {
    private var hosts: [String] = []
    private var paths: [String] = []

    override func setUp() {
        super.setUp()
        hosts = []
        paths = []
        StubURLProtocol.handler = { request in
            self.hosts.append(request.url?.host ?? "")
            self.paths.append(request.url?.path ?? "")
            let body = #"{"code":"1","msg":"stub"}"#
            let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
            return (response, Data(body.utf8))
        }
    }

    override func tearDown() {
        StubURLProtocol.handler = nil
        super.tearDown()
    }

    func test_defaultInit_controllerTalksToTheConfiguredEnvironmentHost() async {
        let checkout = SunbayCheckout(
            configuration: CheckoutConfiguration(environment: .dev),
            urlSession: StubURLProtocol.session())
        let controller = checkout.makeController(
            credentials: CredentialStore(), actionHandler: StubActionHandler())

        _ = try? await controller.start(
            sessionId: "s1", customerAccessSecret: nil, checkoutClientSecret: "ccs_x")

        XCTAssertEqual(hosts, ["checkout.sunbay-dev.com"])
        XCTAssertTrue(paths.first?.hasPrefix("/api/checkout/web/") ?? false)
    }

    func test_defaultInit_usesProductionHostForProduction() async {
        let checkout = SunbayCheckout(
            configuration: CheckoutConfiguration(environment: .production),
            urlSession: StubURLProtocol.session())
        let controller = checkout.makeController(
            credentials: CredentialStore(), actionHandler: StubActionHandler())

        _ = try? await controller.start(
            sessionId: "s1", customerAccessSecret: nil, checkoutClientSecret: "ccs_x")

        XCTAssertEqual(hosts, ["checkout.sunbay.us"])
    }

    /// Thread-safe sink for request bodies observed by the stub protocol.
    private final class BodyRecorder: @unchecked Sendable {
        private let lock = NSLock()
        private var items: [[String: Any]] = []
        func append(_ body: [String: Any]) {
            lock.lock()
            items.append(body)
            lock.unlock()
        }
        var all: [[String: Any]] {
            lock.lock()
            defer { lock.unlock() }
            return items
        }
    }

    private static func readBody(_ request: URLRequest) -> [String: Any] {
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

    private func recordBodies(into recorder: BodyRecorder) {
        StubURLProtocol.handler = { request in
            recorder.append(Self.readBody(request))
            let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
            return (response, Data(#"{"code":"1","msg":"stub"}"#.utf8))
        }
    }

    func test_twoControllers_eachRequestCarriesOnlyItsOwnSecret() async {
        let recorder = BodyRecorder()
        recordBodies(into: recorder)
        let checkout = SunbayCheckout(
            configuration: CheckoutConfiguration(environment: .dev),
            urlSession: StubURLProtocol.session())
        let controllerA = checkout.makeController(
            credentials: CredentialStore(), actionHandler: StubActionHandler())
        let controllerB = checkout.makeController(
            credentials: CredentialStore(), actionHandler: StubActionHandler())

        _ = try? await controllerA.start(
            sessionId: "sA", customerAccessSecret: nil, checkoutClientSecret: "secret-A")
        _ = try? await controllerB.start(
            sessionId: "sB", customerAccessSecret: nil, checkoutClientSecret: "secret-B")

        let secrets = recorder.all.compactMap { $0["checkoutClientSecret"] as? String }
        XCTAssertEqual(secrets, ["secret-A", "secret-B"])
    }

    func test_defaultSubmit_carriesScreenMetricsRecordedOnTheMainActor() async {
        let recorder = BodyRecorder()
        recordBodies(into: recorder)
        let checkout = SunbayCheckout(
            configuration: CheckoutConfiguration(environment: .dev),
            urlSession: StubURLProtocol.session())
        checkout.screenMetrics.record(width: 390, height: 844, scale: 3)
        let (payment, _) = checkout.serviceFactory(CredentialStore())

        // Runs off the main thread, like the real submit path.
        _ = try? await payment.submit(
            SubmitRequest(
                sessionId: "s1", paymentMethod: "CARD", attemptId: UUID(),
                cardEncryptedData: "x", checkoutClientSecret: "ccs"))

        let info = recorder.all.first?["userDeviceInfo"] as? [String: Any]
        XCTAssertEqual(info?["deviceResolution"] as? String, "1170x2532")
        XCTAssertEqual(info?["screenWidth"] as? String, "1170")
        XCTAssertEqual(info?["screenHeight"] as? String, "2532")
    }

    func test_defaultSubmit_withoutRecordedMetricsOmitsResolution() async {
        let recorder = BodyRecorder()
        recordBodies(into: recorder)
        let checkout = SunbayCheckout(
            configuration: CheckoutConfiguration(environment: .dev),
            urlSession: StubURLProtocol.session())
        let (payment, _) = checkout.serviceFactory(CredentialStore())

        _ = try? await payment.submit(
            SubmitRequest(
                sessionId: "s1", paymentMethod: "CARD", attemptId: UUID(),
                cardEncryptedData: "x", checkoutClientSecret: "ccs"))

        let info = recorder.all.first?["userDeviceInfo"] as? [String: Any]
        XCTAssertNil(info?["deviceResolution"])
    }

    func test_defaultInit_listsSavedCardsThroughCardListEndpoint() async {
        StubURLProtocol.handler = { request in
            self.paths.append(request.url?.path ?? "")
            let body: String
            if request.url?.path.hasSuffix("/card/list") == true {
                body = #"{"code":"0","msg":"ok","data":{"cards":[{"savedCardId":"sc_1","maskedCardNumber":"**** **** **** 4242","cardBrand":"VISA","expiryMonth":"07","expiryYear":"29"}]}}"#
            } else {
                body = #"{"code":"0","msg":"ok","data":{"sessionId":"s1","sessionType":"sdk","currency":"USD","totalAmount":1000,"expiresAt":"2030-01-01T00:00:00Z","merchantName":"M","paymentMethods":[{"method":"VISA","type":"CARD"}]}}"#
            }
            let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
            return (response, Data(body.utf8))
        }
        let checkout = SunbayCheckout(
            configuration: CheckoutConfiguration(environment: .dev),
            urlSession: StubURLProtocol.session())
        let controller = checkout.makeController(
            credentials: CredentialStore(), actionHandler: StubActionHandler())

        _ = try? await controller.start(
            sessionId: "s1", customerAccessSecret: "cas_x", checkoutClientSecret: "ccs_x")

        let cards = await controller.listSavedCards()

        XCTAssertTrue(paths.contains { $0.hasSuffix("/card/list") }, "paths: \(paths)")
        XCTAssertEqual(cards.map(\.id), ["sc_1"])
    }

    func test_defaultInit_addressServiceHitsAddressEndpointOnTheDevHost() async throws {
        StubURLProtocol.handler = { request in
            self.hosts.append(request.url?.host ?? "")
            self.paths.append(request.url?.path ?? "")
            let body = #"{"code":"0","msg":"ok","data":{"countries":[{"code":"US","name":"United States"}],"detectedCountry":"US"}}"#
            let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
            return (response, Data(body.utf8))
        }
        let checkout = SunbayCheckout(
            configuration: CheckoutConfiguration(environment: .dev),
            urlSession: StubURLProtocol.session())

        let list = try await checkout.addressMetadataService.countries(locale: "en-US")

        XCTAssertEqual(hosts, ["checkout.sunbay-dev.com"])
        XCTAssertEqual(paths, ["/api/address/country"])
        XCTAssertEqual(list.countries.map(\.code), ["US"])
    }

    func test_injectingInit_stillUsesTheInjectedMock() async throws {
        let payment = MockPaymentService()
        payment.stubSession(
            CheckoutSession(
                id: "s_inj", amount: Amount(minorUnits: 100, currencyCode: "USD"),
                merchantName: "Acme", methods: [.card],
                expiresAt: Date().addingTimeInterval(600), rsaPublicKey: nil, cofEnabled: false))
        let checkout = SunbayCheckout(
            configuration: CheckoutConfiguration(environment: .dev),
            paymentService: payment, cofService: MockCofService())
        let controller = checkout.makeController(
            credentials: CredentialStore(), actionHandler: StubActionHandler())

        _ = try await controller.start(sessionId: "s_inj", customerAccessSecret: nil)

        XCTAssertEqual(payment.loadSessionCallCount, 1)
        XCTAssertTrue(hosts.isEmpty)
    }

    func test_defaultInit_usesTheHTTPCardRulesService() {
        let checkout = SunbayCheckout(
            configuration: CheckoutConfiguration(environment: .dev), urlSession: StubURLProtocol.session())
        XCTAssertTrue(checkout.cardRulesService is HTTPCardRulesService)
    }

    func test_serviceInjectionInit_usesTheEmptyCardRulesService() {
        let checkout = SunbayCheckout(
            configuration: CheckoutConfiguration(environment: .dev),
            paymentService: MockPaymentService(), cofService: MockCofService())
        XCTAssertTrue(checkout.cardRulesService is EmptyCardRulesService)
    }

    #if canImport(UIKit)
        func test_uiWiring_carriesTheCardRulesService() {
            let checkout = SunbayCheckout(
                configuration: CheckoutConfiguration(environment: .dev), urlSession: StubURLProtocol.session())
            XCTAssertTrue(checkout.makeUIWiring().cardRulesService is HTTPCardRulesService)
        }
    #endif
}
