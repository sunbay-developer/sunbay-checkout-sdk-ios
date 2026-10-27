import Foundation

/// SunbayCheckout 的宿主（host）配置入口（product-spec §2.1）。
///
/// 该类型是公共 API 的一部分。首个版本仅定义并存储这些字段，由 `SunbayCheckout`
/// 入口消费；全部可选字段默认 nil。
public struct CheckoutConfiguration: Sendable, Equatable {
    /// 运行环境。
    public enum Environment: Sendable, Equatable {
        /// 测试环境。
        case test
        /// 生产环境。
        case production
    }

    /// 运行环境。
    public let environment: Environment

    /// Apple Pay merchant id，由 host 提供。
    ///
    /// 为 nil 时改用 session 下发的 id（两种 merchant-id 模型、同一条代码路径；
    /// host 配置优先，见 `resolveMerchantId`）。
    public let applePayMerchantId: String?

    /// 外观 / 配色配置（首版仅存储，不消费）。
    public let appearance: Appearance?

    /// 语言环境（如 `"zh-CN"`）。
    public let locale: String?

    /// 创建一个配置。
    ///
    /// - Parameters:
    ///   - environment: 运行环境。
    ///   - applePayMerchantId: host 配置的 Apple Pay merchant id；默认 nil（回退到 session）。
    ///   - appearance: 外观配置；默认 nil。
    ///   - locale: 语言环境；默认 nil。
    public init(
        environment: Environment,
        applePayMerchantId: String? = nil,
        appearance: Appearance? = nil,
        locale: String? = nil
    ) {
        self.environment = environment
        self.applePayMerchantId = applePayMerchantId
        self.appearance = appearance
        self.locale = locale
    }
}
