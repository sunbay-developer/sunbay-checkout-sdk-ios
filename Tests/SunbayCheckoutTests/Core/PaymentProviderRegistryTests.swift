import XCTest

@testable import SunbayCheckout

final class PaymentProviderRegistryTests: XCTestCase {
    private let visa = MethodEntry(method: "VISA", type: "CARD", name: "Visa", logoURL: nil)
    private let apple = MethodEntry(method: "APPLE_PAY", type: "E_WALLET", name: "Apple Pay", logoURL: nil)

    func test_cardAndApplePay_areGrouped_expressFirst() {
        let providers = PaymentProviderRegistry.available(entries: [visa, apple]) { _ in true }
        XCTAssertEqual(providers.map(\.key), ["APPLE_PAY", "CARD"])
        XCTAssertEqual(providers.map(\.kind), [.express, .normal])
    }

    func test_applePayStaticFalse_leavesCardOnly() {
        let providers = PaymentProviderRegistry.available(entries: [visa, apple]) { $0.key != "APPLE_PAY" }
        XCTAssertEqual(providers.map(\.key), ["CARD"])
    }

    func test_cardHidden_leavesApplePayOnly() {
        let providers = PaymentProviderRegistry.available(entries: [apple]) { _ in true }
        XCTAssertEqual(providers.map(\.key), ["APPLE_PAY"])
    }

    func test_noEntries_isEmpty() {
        XCTAssertTrue(PaymentProviderRegistry.available(entries: []) { _ in true }.isEmpty)
    }
}
