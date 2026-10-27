import Foundation

/// 单笔结账会话的 Core 领域模型。
///
/// 这是 UI 无关的内部模型（故为 `internal`），由后端会话 JSON 解码得到，
/// 承载渲染可用支付方式与确认支付所需的全部信息。
struct CheckoutSession: Sendable, Equatable {
    /// 会话标识。
    let id: String
    /// 本次支付金额。
    let amount: Amount
    /// 商户展示名称。
    let merchantName: String
    /// 本会话可用的支付方式集合。
    let methods: Set<PaymentMethodKind>
    /// 会话过期时间。
    let expiresAt: Date
    /// 用于本地加密卡数据的 RSA 公钥（base64）；不可用时为 nil。
    let rsaPublicKey: String?
    /// 是否启用 COF（已保存卡 / one-tap）。
    let cofEnabled: Bool
}

/// 支付方式类型。
enum PaymentMethodKind: String, Sendable {
    /// 新卡。
    case card
    /// Apple Pay 钱包。
    case applePay
    /// 已保存卡（COF）。
    case savedCard
}
