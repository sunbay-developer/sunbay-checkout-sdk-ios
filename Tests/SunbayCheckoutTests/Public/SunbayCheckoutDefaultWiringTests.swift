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

    func test_twoControllers_getDistinctCredentialStores() {
        let checkout = SunbayCheckout(
            configuration: CheckoutConfiguration(environment: .dev),
            urlSession: StubURLProtocol.session())
        let storeA = CredentialStore()
        let storeB = CredentialStore()
        var seen: [CredentialStore] = []
        let probe = SunbayCheckout(
            configuration: CheckoutConfiguration(environment: .dev),
            serviceFactory: { store in
                seen.append(store)
                return (MockPaymentService(), MockCofService())
            })
        _ = probe.makeController(credentials: storeA, actionHandler: StubActionHandler())
        _ = probe.makeController(credentials: storeB, actionHandler: StubActionHandler())
        _ = checkout

        XCTAssertEqual(seen.count, 2)
        XCTAssertTrue(seen[0] === storeA)
        XCTAssertTrue(seen[1] === storeB)
        XCTAssertFalse(seen[0] === seen[1])
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
}
