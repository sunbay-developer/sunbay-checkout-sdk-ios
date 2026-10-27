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
        // clear() 幂等:重复调用不崩溃,current 持续为 nil。
        await store.clear()
        await store.clear()
        let current = await store.current()
        XCTAssertNil(current)
    }
}
