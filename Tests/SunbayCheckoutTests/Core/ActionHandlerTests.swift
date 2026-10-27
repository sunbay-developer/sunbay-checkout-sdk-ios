import Foundation
import XCTest

@testable import SunbayCheckout

/// `requiresAction` (R) dispatch tests for `ActionHandler` (Task 8 Step 1).
///
/// Covers product-spec §4.5: `redirect` → open the payment page with the injected `WebAuthOpening` then
/// return `.pending`; `qrCode` / `showContent` / unknown type → `.failed(UNSUPPORTED_CAPABILITY)`, and
/// does **not** call the opener (no silent hang).
///
/// Review Focus: unsupported action types map to `failed(UNSUPPORTED_CAPABILITY)` rather than silently
/// waiting; after `redirect` opens, the result is `pending`.
final class ActionHandlerTests: XCTestCase {
    // MARK: - WebAuthOpening double: records the opened URL (actor guarantees Sendable safety)

    /// Records the URL received by each `open(_:)`. `ActionHandler` calls it within `await`, so an actor isolates it.
    private actor SpyWebAuthOpener: WebAuthOpening {
        private(set) var openedURLs: [URL] = []

        func open(_ url: URL) async {
            openedURLs.append(url)
        }
    }

    // MARK: - 1. redirect → opens the URL once, result .pending

    func test_redirect_opensURLOnce_andReturnsPending() async {
        let spy = SpyWebAuthOpener()
        let handler = ActionHandler(webAuthOpener: spy)
        let url = URL(string: "https://apm.example.com/pay?token=abc")!

        let result = await handler.handle(.redirect(url: url), sessionId: "sess_1")

        let opened = await spy.openedURLs
        XCTAssertEqual(opened, [url], "redirect should open the URL exactly once")
        guard case .pending = result else {
            return XCTFail("redirect should return .pending after opening, got \(result)")
        }
    }

    // MARK: - 2. qrCode → .failed(UNSUPPORTED_CAPABILITY), does not call the opener

    func test_qrCode_returnsUnsupportedCapability_withoutOpening() async {
        let spy = SpyWebAuthOpener()
        let handler = ActionHandler(webAuthOpener: spy)

        let result = await handler.handle(.qrCode, sessionId: "sess_1")

        let opened = await spy.openedURLs
        XCTAssertTrue(opened.isEmpty, "qrCode should not call the opener")
        assertUnsupportedCapability(result)
    }

    // MARK: - 3. showContent → .failed(UNSUPPORTED_CAPABILITY), does not call the opener

    func test_showContent_returnsUnsupportedCapability_withoutOpening() async {
        let spy = SpyWebAuthOpener()
        let handler = ActionHandler(webAuthOpener: spy)

        let result = await handler.handle(.showContent, sessionId: "sess_1")

        let opened = await spy.openedURLs
        XCTAssertTrue(opened.isEmpty, "showContent should not call the opener")
        assertUnsupportedCapability(result)
    }

    // MARK: - 4. unknown → .failed(UNSUPPORTED_CAPABILITY), does not call the opener

    func test_unknown_returnsUnsupportedCapability_withoutOpening() async {
        let spy = SpyWebAuthOpener()
        let handler = ActionHandler(webAuthOpener: spy)

        let result = await handler.handle(.unknown, sessionId: "sess_1")

        let opened = await spy.openedURLs
        XCTAssertTrue(opened.isEmpty, "unknown should not call the opener")
        assertUnsupportedCapability(result)
    }

    // MARK: - Assertion helper

    /// Asserts the result is `.failed` with error code `UNSUPPORTED_CAPABILITY` and category `.runtime`.
    private func assertUnsupportedCapability(
        _ result: ActionResult,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        guard case let .failed(error) = result else {
            return XCTFail("should return .failed, got \(result)", file: file, line: line)
        }
        XCTAssertEqual(error.code, "UNSUPPORTED_CAPABILITY", file: file, line: line)
        XCTAssertEqual(error.category, .runtime, file: file, line: line)
    }
}
