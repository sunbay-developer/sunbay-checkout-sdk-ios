import Foundation

/// 已保存卡（COF）的只读展示信息。
///
/// 仅包含用于列表展示的非敏感信息（品牌与末四位），不含完整卡号或 CVV。
public struct SavedCard: Sendable, Equatable {
    /// 已保存支付方式的标识。
    public let id: String
    /// 卡品牌（如 `"visa"`）。
    public let brand: String
    /// 卡号末四位。
    public let last4: String
    /// 有效期月份。
    public let expMonth: Int
    /// 有效期年份。
    public let expYear: Int

    /// 创建一个已保存卡展示信息。
    ///
    /// - Parameters:
    ///   - id: 已保存支付方式的标识。
    ///   - brand: 卡品牌。
    ///   - last4: 卡号末四位。
    ///   - expMonth: 有效期月份。
    ///   - expYear: 有效期年份。
    public init(id: String, brand: String, last4: String, expMonth: Int, expYear: Int) {
        self.id = id
        self.brand = brand
        self.last4 = last4
        self.expMonth = expMonth
        self.expYear = expYear
    }
}
