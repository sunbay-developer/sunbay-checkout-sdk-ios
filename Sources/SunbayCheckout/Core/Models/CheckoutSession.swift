import Foundation

/// 单笔结账会话的 Core 领域模型。
///
/// UI 无关的领域模型，由后端会话 JSON 解码得到，承载渲染可用支付方式与确认支付所需的
/// 全部信息。
///
/// - Note: 自 Task 11.5 起**公开**（`public`）：host 自实现的 `PaymentService.loadSession`
///   必须返回本类型，因此它是公共服务契约的一部分。所携带字段（金额/商户/方式/过期/公钥/COF 开关）
///   均非机密；`rsaPublicKey` 是**公钥**（非密钥），以普通 `public let` 暴露。
public struct CheckoutSession: Sendable, Equatable {
    /// 会话标识。
    public let id: String
    /// 本次支付金额。
    public let amount: Amount
    /// 商户展示名称。
    public let merchantName: String
    /// 本会话可用的支付方式集合。
    public let methods: Set<PaymentMethodKind>
    /// 会话过期时间。
    public let expiresAt: Date
    /// 用于本地加密卡数据的 RSA **公钥**（base64）；不可用时为 nil。公钥非机密。
    public let rsaPublicKey: String?
    /// 是否启用 COF（已保存卡 / one-tap）。
    public let cofEnabled: Bool

    /// 创建一个结账会话（host 的 `PaymentService.loadSession` 构造并返回）。
    ///
    /// - Parameters:
    ///   - id: 会话标识。
    ///   - amount: 本次支付金额。
    ///   - merchantName: 商户展示名称。
    ///   - methods: 本会话可用的支付方式集合。
    ///   - expiresAt: 会话过期时间。
    ///   - rsaPublicKey: 本地加密卡数据用的 RSA 公钥（base64），默认 nil。
    ///   - cofEnabled: 是否启用 COF，默认 false。
    public init(
        id: String,
        amount: Amount,
        merchantName: String,
        methods: Set<PaymentMethodKind>,
        expiresAt: Date,
        rsaPublicKey: String? = nil,
        cofEnabled: Bool = false
    ) {
        self.id = id
        self.amount = amount
        self.merchantName = merchantName
        self.methods = methods
        self.expiresAt = expiresAt
        self.rsaPublicKey = rsaPublicKey
        self.cofEnabled = cofEnabled
    }
}

/// 支付方式类型。
///
/// 自 Task 11.5 起**公开**：随 `CheckoutSession.methods` 跨公共边界。
public enum PaymentMethodKind: String, Sendable {
    /// 新卡。
    case card
    /// Apple Pay 钱包。
    case applePay
    /// 已保存卡（COF）。
    case savedCard
}
