import Foundation

/// SunbayCheckout SDK 的公共入口（product-spec §2.1）。
///
/// host 以一份 `CheckoutConfiguration` 构造本对象，再交给后续任务的 UI 外壳
/// （`PaymentSheet` / `ApplePayButton`）按 `sessionId` 发起结账。
///
/// - Note: 版本常量 `sunbayCheckoutVersion` 位于独立的 `Version.swift`，与本入口**类**
///   同名不冲突（文件名不同，符号不同）。
///
/// 公共表面刻意最小：仅 `init(configuration:)` 与只读的 `configuration`。
/// 构造 `CheckoutController` 的工厂（`makeController`）是 **internal** 缝，供同模块内的
/// UI 外壳在后续任务里按 `sessionId` 组装控制器与注入服务，不对外暴露。
public final class SunbayCheckout {
    /// host 提供的配置（只读）。
    public let configuration: CheckoutConfiguration

    /// 以配置创建入口。
    ///
    /// - Parameter configuration: host 配置。
    public init(configuration: CheckoutConfiguration) {
        self.configuration = configuration
    }

    // MARK: - Internal 工厂缝（供 PaymentSheet / ApplePayButton 使用）

    /// 为给定会话组装一个 `CheckoutController`（internal DI 缝）。
    ///
    /// 依赖以协议注入，便于 mock/real 互换（product-spec 全局约束）。后续任务的 UI 外壳
    /// 以此按 `sessionId` 组装控制器；本方法不触碰任何 UIKit/PassKit。
    ///
    /// - Parameters:
    ///   - paymentService: 支付后端能力。
    ///   - cofService: 已保存卡能力。
    ///   - credentials: 内存凭证持有者。
    ///   - actionHandler: `requiresAction` 分发器。
    /// - Returns: 组装好的控制器。
    func makeController(
        paymentService: any PaymentService,
        cofService: any CofService,
        credentials: CredentialStore,
        actionHandler: any ActionHandling
    ) -> CheckoutController {
        CheckoutController(
            paymentService: paymentService,
            cofService: cofService,
            credentials: credentials,
            actionHandler: actionHandler
        )
    }
}
