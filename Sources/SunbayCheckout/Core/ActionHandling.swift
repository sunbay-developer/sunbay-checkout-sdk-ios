import Foundation

/// `requiresAction`(R)动作的分发注入点(seam)。
///
/// 这是 Task 8(`ActionHandler`)落地前的协议缝:`CheckoutController` 只依赖本协议,
/// 真实实现(redirect → `ASWebAuthenticationSession`;qrCode/showContent → UNSUPPORTED_CAPABILITY,
/// 见 product-spec §4.5)由 Task 8 提供,从而本任务可先行落地。测试用一个脚本化替身。
///
/// UI 无关:协议本身不依赖任何 UIKit/PassKit 类型(Core 约束,见 AGENTS.md §2.6)。
protocol ActionHandling: Sendable {
    /// 处理一个进一步动作。
    ///
    /// - Parameters:
    ///   - action: 后端在 `R` 状态下携带的动作(见 `PaymentAction`)。
    ///   - sessionId: 当前会话标识。
    /// - Returns: 处理结果:`.pending`(如已打开跳转、等待回跳/轮询)或 `.failed`(不支持等)。
    func handle(_ action: PaymentAction, sessionId: String) async -> ActionResult
}

/// `ActionHandling.handle` 的结果。
///
/// 首版语义(§4.5):`redirect` → 打开后 `.pending`;`qrCode` / `showContent` / 未知 →
/// `.failed(UNSUPPORTED_CAPABILITY)`。控制器据此映射为 `CheckoutOutcome`。
enum ActionResult: Sendable {
    /// 动作已触发,交易仍处理中(需轮询 / 回跳确认终态)。
    case pending
    /// 动作无法处理(如不支持的能力)。
    case failed(CheckoutError)
}
