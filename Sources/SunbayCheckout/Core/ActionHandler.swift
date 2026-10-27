import Foundation

/// 打开 Web 认证会话的注入缝(seam)。
///
/// 包装系统 `ASWebAuthenticationSession`:真实实现由 Task 11
/// (`UI/Wallet/WebAuthOpener.swift`)提供,本任务只定义协议,测试注入替身。
///
/// 通过协议解耦使 `ActionHandler` 保持 Core 纯净(UI 无关,见 AGENTS.md §2.6):
/// 本文件**不**导入 AuthenticationServices / UIKit。
protocol WebAuthOpening: Sendable {
    /// 打开一个用于第三方 APM 跳转的支付网页(带 returnUrl 回跳)。
    ///
    /// - Parameter url: 后端在 `redirect` 动作中下发的跳转地址。
    func open(_ url: URL) async
}

/// `ActionHandling` 的首版具体实现:按 `PaymentAction` 类型分发(见 product-spec §4.5)。
///
/// 语义:
/// - `redirect` → 通过注入的 `webAuthOpener` 打开支付页,随后返回 `.pending`
///   (由控制器继续轮询 / 回跳确认终态)。
/// - `qrCode` / `showContent` / `unknown` → 返回 `.failed(UNSUPPORTED_CAPABILITY)`,
///   **不**调用 opener(不静默挂起)。
///
/// Core 纯净:仅依赖 `WebAuthOpening` 协议,不接触任何 UI 框架类型。
struct ActionHandler: ActionHandling {
    /// 打开 Web 认证会话的注入缝;真实实现见 Task 11。
    private let webAuthOpener: any WebAuthOpening

    /// 创建一个动作处理器。
    ///
    /// - Parameter webAuthOpener: `redirect` 动作用于打开支付页的注入缝。
    init(webAuthOpener: any WebAuthOpening) {
        self.webAuthOpener = webAuthOpener
    }

    /// 处理一个 `requiresAction` 动作(见 `ActionHandling.handle`)。
    ///
    /// - Parameters:
    ///   - action: 后端在 `R` 状态下携带的动作。
    ///   - sessionId: 当前会话标识(首版 `redirect` 流程不直接使用,预留用于诊断 / 回跳匹配)。
    /// - Returns: `redirect` → `.pending`;其余 → `.failed(UNSUPPORTED_CAPABILITY)`。
    func handle(_ action: PaymentAction, sessionId: String) async -> ActionResult {
        switch action {
        case let .redirect(url):
            await webAuthOpener.open(url)
            return .pending
        case .qrCode, .showContent, .unknown:
            return .failed(
                CheckoutError(
                    code: "UNSUPPORTED_CAPABILITY",
                    message: "This payment action type is not supported in this SDK version.",
                    category: .runtime,
                    traceId: nil
                )
            )
        }
    }
}
