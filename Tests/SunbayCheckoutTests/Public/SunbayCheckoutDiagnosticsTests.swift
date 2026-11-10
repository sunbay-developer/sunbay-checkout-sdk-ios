import XCTest

@testable import SunbayCheckout

final class SunbayCheckoutDiagnosticsTests: XCTestCase {
    private func makeCheckout() -> SunbayCheckout {
        SunbayCheckout(configuration: CheckoutConfiguration(environment: .dev))
    }

    func test_onDiagnostic_setBefore_receivesWarning() {
        let checkout = makeCheckout()
        let e = expectation(description: "received")
        checkout.onDiagnostic = { _ in e.fulfill() }
        checkout.diagnostics.warning(.walletParamsInvalid, ignored: ["a"], reason: "r", sessionId: nil)
        wait(for: [e], timeout: 2)
    }

    func test_onDiagnostic_setAfter_replays() {
        let checkout = makeCheckout()
        checkout.diagnostics.warning(.walletParamsInvalid, ignored: ["a"], reason: "r", sessionId: nil)
        let e = expectation(description: "replayed")
        checkout.onDiagnostic = { _ in e.fulfill() }
        wait(for: [e], timeout: 2)
    }
}
