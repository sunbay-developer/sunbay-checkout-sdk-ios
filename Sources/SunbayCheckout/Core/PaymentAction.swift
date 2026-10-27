import Foundation

/// `requiresAction`(R)状态下后端下发的进一步动作。
///
/// 源自后端结果 JSON 的 `action.type`(见 product-spec §7.4 / §4.5)。首版仅实现 `redirect`;
/// `qrCode` / `showContent` 为协议预留(运行时按 UNSUPPORTED_CAPABILITY 处理,见 Task 8);
/// 无法识别的类型降级为 `.unknown`,解码阶段不崩溃。
enum PaymentAction: Sendable, Equatable {
    /// 跳转到第三方支付网页(`action.redirectUrl`)。
    case redirect(url: URL)
    /// 展示二维码(首版不实现)。
    case qrCode
    /// 展示内容(首版不实现)。
    case showContent
    /// 未知 / 不支持的动作类型。
    case unknown
}
