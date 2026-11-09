import XCTest

@testable import SunbayCheckout

final class CredentialStoreTests: XCTestCase {
    func test_hold_thenCurrent_returnsHeldSecret() async {
        let store = CredentialStore()
        await store.hold(customerAccessSecret: "secret-abc")
        let current = await store.current()
        XCTAssertEqual(current, "secret-abc")
    }

    func test_clear_thenCurrent_returnsNil() async {
        let store = CredentialStore()
        await store.hold(customerAccessSecret: "secret-abc")
        await store.clear()
        let current = await store.current()
        XCTAssertNil(current)
    }

    func test_clear_calledTwice_isSafe_andCurrentStaysNil() async {
        let store = CredentialStore()
        await store.hold(customerAccessSecret: "secret-abc")
        // clear() is idempotent: repeated calls do not crash, and current stays nil.
        await store.clear()
        await store.clear()
        let current = await store.current()
        XCTAssertNil(current)
    }

    func test_clear_emptiesBothSecrets() async {
        let store = CredentialStore()
        await store.hold(customerAccessSecret: "cas")
        await store.hold(checkoutClientSecret: "ccs")
        let heldClient = await store.currentCheckoutClientSecret()
        XCTAssertEqual(heldClient, "ccs")
        await store.clear()
        let a = await store.current()
        let b = await store.currentCheckoutClientSecret()
        XCTAssertNil(a)
        XCTAssertNil(b)
    }
}
