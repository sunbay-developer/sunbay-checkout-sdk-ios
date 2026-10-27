import Foundation

/// 一次结账流程对外返回的结果。
///
/// 该枚举是公共 API 的一部分，表达结账的终态与中间态；绝不包含任何敏感数据。
public enum CheckoutOutcome: Sendable {
    /// 支付成功，携带交易标识。
    case succeeded(txnId: String)
    /// 支付失败，携带交易标识（可能为 nil）与错误信息。
    case failed(txnId: String?, error: CheckoutError)
    /// 用户取消。
    case canceled
    /// 支付处理中（非终态），携带交易标识（可能为 nil）。
    case pending(txnId: String?)
    /// 结果未知（如提交超时后无法确认），携带会话标识以便后续查询。
    case unknown(sessionId: String)
}
