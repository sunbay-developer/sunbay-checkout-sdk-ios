import Foundation

/// 结账过程中对外暴露的错误。
///
/// 该类型是公共 API 的一部分，承载可供宿主 App 展示 / 上报的错误信息，
/// 但绝不包含任何敏感数据（卡号、钱包令牌、密文等）。
public struct CheckoutError: Error, Sendable {
    /// 错误分类。
    public enum Category: Sendable, Equatable {
        /// 配置错误（如缺少必要的商户配置）。
        case configuration
        /// 校验错误（如卡信息不合法）。
        case validation
        /// 网络错误。
        case network
        /// 运行时错误。
        case runtime
        /// 支付错误（如被拒付）。
        case payment
    }

    /// 稳定的错误码。
    public let code: String
    /// 面向开发者的错误描述。
    public let message: String
    /// 错误分类。
    public let category: Category
    /// 后端链路追踪标识；不可用时为 nil。
    public let traceId: String?

    /// 创建一个结账错误。
    ///
    /// - Parameters:
    ///   - code: 稳定的错误码。
    ///   - message: 面向开发者的错误描述。
    ///   - category: 错误分类。
    ///   - traceId: 后端链路追踪标识，可为 nil。
    public init(code: String, message: String, category: Category, traceId: String?) {
        self.code = code
        self.message = message
        self.category = category
        self.traceId = traceId
    }
}
