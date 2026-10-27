import Foundation

/// 支付金额。
///
/// 金额以整数最小货币单位（minor units）表示，避免浮点误差；例如 9.99 USD
/// 记作 `minorUnits = 999`、`currencyCode = "USD"`。
public struct Amount: Sendable, Equatable {
    /// 最小货币单位数量（如「分」）。
    public let minorUnits: Int64
    /// ISO 4217 货币代码（如 `"USD"`）。
    public let currencyCode: String

    /// 创建一个金额。
    ///
    /// - Parameters:
    ///   - minorUnits: 最小货币单位数量。
    ///   - currencyCode: ISO 4217 货币代码。
    public init(minorUnits: Int64, currencyCode: String) {
        self.minorUnits = minorUnits
        self.currencyCode = currencyCode
    }
}
