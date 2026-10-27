import Foundation

/// 保存卡时附带的用户同意信息(COF)。
///
/// 对应 product-spec §7.3 请求体中的 `consent` 字段。`save` 新卡时必填。
struct Consent: Codable, Sendable {
    /// 同意条款版本。
    let version: String
    /// 未来使用方式;当前固定为 `"ON_SESSION"`。
    let futureUsage: String

    /// 创建一个同意信息。
    ///
    /// - Parameters:
    ///   - version: 同意条款版本。
    ///   - futureUsage: 未来使用方式,默认 `"ON_SESSION"`。
    init(version: String, futureUsage: String = "ON_SESSION") {
        self.version = version
        self.futureUsage = futureUsage
    }
}

/// 一次支付提交请求(Core 内部表示)。
///
/// 对应 product-spec §7.3 的提交契约与 COF 扩展。承载三条支付路径所需的字段:
/// 新卡(`cardEncryptedData`)、钱包(`walletToken`)、已保存卡(`paymentMethodId`)。
///
/// - Note: 敏感字段(`cardEncryptedData` / `walletToken`)绝不进入日志或公开回调(见 §5)。
struct SubmitRequest: Sendable {
    /// 会话标识。
    let sessionId: String
    /// 支付方式标识(如 `"VISA"` / `"APPLE_PAY"`)。
    let paymentMethod: String
    /// 本次确认的尝试标识;每次 confirm 生成一个,用于幂等与去重。
    let attemptId: UUID
    /// 卡密文(§7.2);新卡路径使用,其他路径为 nil。
    let cardEncryptedData: String?
    /// 钱包 token(Apple Pay);其他路径为 nil。
    let walletToken: Data?
    /// 已保存卡标识(COF);其他路径为 nil。与 `savePaymentMethod` 互斥。
    let paymentMethodId: String?
    /// 用新卡时是否请求保存(COF)。
    let savePaymentMethod: Bool?
    /// 保存卡时的用户同意;`savePaymentMethod == true` 时应提供。
    let consent: Consent?

    /// 创建一次支付提交请求。
    ///
    /// - Parameters:
    ///   - sessionId: 会话标识。
    ///   - paymentMethod: 支付方式标识。
    ///   - attemptId: 本次确认的尝试标识。
    ///   - cardEncryptedData: 卡密文,默认 nil。
    ///   - walletToken: 钱包 token,默认 nil。
    ///   - paymentMethodId: 已保存卡标识,默认 nil。
    ///   - savePaymentMethod: 是否请求保存新卡,默认 nil。
    ///   - consent: 保存卡同意信息,默认 nil。
    init(
        sessionId: String,
        paymentMethod: String,
        attemptId: UUID,
        cardEncryptedData: String? = nil,
        walletToken: Data? = nil,
        paymentMethodId: String? = nil,
        savePaymentMethod: Bool? = nil,
        consent: Consent? = nil
    ) {
        self.sessionId = sessionId
        self.paymentMethod = paymentMethod
        self.attemptId = attemptId
        self.cardEncryptedData = cardEncryptedData
        self.walletToken = walletToken
        self.paymentMethodId = paymentMethodId
        self.savePaymentMethod = savePaymentMethod
        self.consent = consent
    }
}

/// 支付后端能力契约(UI 无关)。
///
/// 对应 product-spec §7.1(加载会话)、§7.3(提交)、§7.4(查询结果)。首版用 mock 实现,
/// 真实接口 ready 后只替换适配器,不动 Core/UI。
protocol PaymentService: Sendable {
    /// 加载指定会话。
    func loadSession(_ id: String) async throws -> CheckoutSession
    /// 提交一次支付。
    func submit(_ req: SubmitRequest) async throws -> PaymentSnapshot
    /// 查询支付结果。
    func getResult(sessionId: String) async throws -> PaymentSnapshot
}
