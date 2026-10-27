import Foundation
import XCTest

@testable import SunbayCheckout

/// `ActionHandler` 的 `requiresAction`(R)分发测试(Task 8 Step 1)。
///
/// 覆盖 product-spec §4.5:`redirect` → 用注入的 `WebAuthOpening` 打开支付页后返回 `.pending`;
/// `qrCode` / `showContent` / 未知类型 → `.failed(UNSUPPORTED_CAPABILITY)`,**不**调用 opener(不静默挂起)。
///
/// Review Focus:不支持的动作类型映射为 `failed(UNSUPPORTED_CAPABILITY)`,而非静默等待;
/// `redirect` 打开后进入 `pending`。
final class ActionHandlerTests: XCTestCase {
    // MARK: - WebAuthOpening 替身:记录被打开的 URL(actor 保证 Sendable 安全)

    /// 记录每次 `open(_:)` 收到的 URL。`ActionHandler` 在 `await` 中调用,故用 actor 隔离。
    private actor SpyWebAuthOpener: WebAuthOpening {
        private(set) var openedURLs: [URL] = []

        func open(_ url: URL) async {
            openedURLs.append(url)
        }
    }

    // MARK: - 1. redirect → 打开一次该 URL,结果 .pending

    func test_redirect_opensURLOnce_andReturnsPending() async {
        let spy = SpyWebAuthOpener()
        let handler = ActionHandler(webAuthOpener: spy)
        let url = URL(string: "https://apm.example.com/pay?token=abc")!

        let result = await handler.handle(.redirect(url: url), sessionId: "sess_1")

        let opened = await spy.openedURLs
        XCTAssertEqual(opened, [url], "redirect 应恰好打开一次该 URL")
        guard case .pending = result else {
            return XCTFail("redirect 打开后应返回 .pending,实得 \(result)")
        }
    }

    // MARK: - 2. qrCode → .failed(UNSUPPORTED_CAPABILITY),不调用 opener

    func test_qrCode_returnsUnsupportedCapability_withoutOpening() async {
        let spy = SpyWebAuthOpener()
        let handler = ActionHandler(webAuthOpener: spy)

        let result = await handler.handle(.qrCode, sessionId: "sess_1")

        let opened = await spy.openedURLs
        XCTAssertTrue(opened.isEmpty, "qrCode 不应调用 opener")
        assertUnsupportedCapability(result)
    }

    // MARK: - 3. showContent → .failed(UNSUPPORTED_CAPABILITY),不调用 opener

    func test_showContent_returnsUnsupportedCapability_withoutOpening() async {
        let spy = SpyWebAuthOpener()
        let handler = ActionHandler(webAuthOpener: spy)

        let result = await handler.handle(.showContent, sessionId: "sess_1")

        let opened = await spy.openedURLs
        XCTAssertTrue(opened.isEmpty, "showContent 不应调用 opener")
        assertUnsupportedCapability(result)
    }

    // MARK: - 4. unknown → .failed(UNSUPPORTED_CAPABILITY),不调用 opener

    func test_unknown_returnsUnsupportedCapability_withoutOpening() async {
        let spy = SpyWebAuthOpener()
        let handler = ActionHandler(webAuthOpener: spy)

        let result = await handler.handle(.unknown, sessionId: "sess_1")

        let opened = await spy.openedURLs
        XCTAssertTrue(opened.isEmpty, "unknown 不应调用 opener")
        assertUnsupportedCapability(result)
    }

    // MARK: - 断言辅助

    /// 断言结果为 `.failed`,且错误码为 `UNSUPPORTED_CAPABILITY`、分类为 `.runtime`。
    private func assertUnsupportedCapability(
        _ result: ActionResult,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        guard case let .failed(error) = result else {
            return XCTFail("应返回 .failed,实得 \(result)", file: file, line: line)
        }
        XCTAssertEqual(error.code, "UNSUPPORTED_CAPABILITY", file: file, line: line)
        XCTAssertEqual(error.category, .runtime, file: file, line: line)
    }
}
