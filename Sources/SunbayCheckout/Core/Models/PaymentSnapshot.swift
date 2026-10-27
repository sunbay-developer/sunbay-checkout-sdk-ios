import Foundation

/// 后端交易状态。
///
/// 原始值与后端契约一致：`I`（初始 / 处理中）、`S`（成功）、`F`（失败）、
/// `R`（需要进一步动作）。`S` 与 `F` 为终态。
public enum TxnStatus: String, Sendable {
    /// 初始 / 处理中。
    case initial = "I"
    /// 成功（终态）。
    case succeeded = "S"
    /// 失败（终态）。
    case failed = "F"
    /// 需要进一步动作。
    case requiresAction = "R"
}

/// 一次支付结果查询的快照。
public struct PaymentSnapshot: Sendable, Equatable {
    /// 会话标识。
    public let sessionId: String
    /// 当前交易状态。
    public let status: TxnStatus
    /// 交易标识；尚未分配时为 nil。
    public let txnId: String?

    /// 创建一个支付快照。
    ///
    /// - Parameters:
    ///   - sessionId: 会话标识。
    ///   - status: 当前交易状态。
    ///   - txnId: 交易标识，可为 nil。
    public init(sessionId: String, status: TxnStatus, txnId: String?) {
        self.sessionId = sessionId
        self.status = status
        self.txnId = txnId
    }
}
