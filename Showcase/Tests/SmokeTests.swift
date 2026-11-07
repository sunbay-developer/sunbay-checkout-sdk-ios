import XCTest

// Throwaway smoke test so the test target is valid; removed in Task 2.
final class SmokeTests: XCTestCase {
    func testBundleIdentifier() {
        XCTAssertEqual(Bundle.main.bundleIdentifier, "com.sunbay.checkout.showcase")
    }
}
