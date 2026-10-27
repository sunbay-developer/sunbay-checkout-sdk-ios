import Foundation

/// SunbayCheckout SDK 的公共入口（product-spec §2.1）。
///
/// host 以一份 `CheckoutConfiguration` 构造本对象，再交给 UI 外壳（`PaymentSheet` /
/// `ApplePayButton`）按 `sessionId` 发起结账。
///
/// ## 服务注入（Task 11.5）
/// 真实支付需要一对后端能力：`PaymentService`（加载会话 / 提交 / 查询结果）与
/// `CofService`（列已保存卡）。SDK **不**自带真实 HTTP 适配器（后端契约未定，§7/§8）；
/// 由 host（或示例 app）通过 `init(configuration:paymentService:cofService:)` 注入自实现
/// （mock 或真实后端适配器），即可用公共 UI 跑通端到端支付。
///
/// 朴素的 `init(configuration:)` 仍保留（源码兼容）：未注入服务时回退到共享的 fail-closed
/// `Unconfigured*` 默认——任何调用都抛 `NETWORK_UNAVAILABLE`，绝不静默成功。
///
/// - Note: 版本常量 `sunbayCheckoutVersion` 位于独立的 `Version.swift`，与本入口**类**
///   同名不冲突（文件名不同，符号不同）。
///
/// 构造 `CheckoutController` 的工厂（`makeController`）是 **internal** 缝，供同模块内的
/// UI 外壳按 `sessionId` 组装控制器并注入服务，不对外暴露。
public final class SunbayCheckout {
    /// host 提供的配置（只读）。
    public let configuration: CheckoutConfiguration

    /// host 注入（或默认 fail-closed）的支付后端能力。internal：不对外暴露，供 UI 外壳 / 缝使用。
    let paymentService: any PaymentService

    /// host 注入（或默认 fail-closed）的已保存卡能力。internal。
    let cofService: any CofService

    /// 以配置创建入口（朴素 init，源码兼容）。
    ///
    /// 未注入后端服务，`makeController` 将使用共享的 fail-closed `Unconfigured*` 默认：
    /// 任何支付调用都抛 `NETWORK_UNAVAILABLE`（不静默成功）。需要跑通真实/mock 支付时，
    /// 改用 `init(configuration:paymentService:cofService:)`。
    ///
    /// - Parameter configuration: host 配置。
    public convenience init(configuration: CheckoutConfiguration) {
        self.init(
            configuration: configuration,
            paymentService: UnconfiguredPaymentService(),
            cofService: UnconfiguredCofService()
        )
    }

    /// 以配置与 host 提供的后端服务创建入口（服务注入缝，Task 11.5）。
    ///
    /// host 实现 `PaymentService` / `CofService`（mock 或真实后端适配器）并由此注入；
    /// 公共 UI（`ApplePayButton` / 后续 `PaymentSheet`）据此驱动端到端支付，无需改动 Core/UI。
    ///
    /// - Parameters:
    ///   - configuration: host 配置。
    ///   - paymentService: host 提供的支付后端能力。
    ///   - cofService: host 提供的已保存卡能力。
    public init(
        configuration: CheckoutConfiguration,
        paymentService: any PaymentService,
        cofService: any CofService
    ) {
        self.configuration = configuration
        self.paymentService = paymentService
        self.cofService = cofService
    }

    // MARK: - Internal 工厂缝（供 PaymentSheet / ApplePayButton 使用）

    /// 用本实例持有的（注入或默认）服务组装一个 `CheckoutController`（internal DI 缝）。
    ///
    /// 这是 UI 外壳的首选入口：服务来源对外壳透明——host 注入了就用注入的，否则用 fail-closed
    /// 默认。本方法不触碰任何 UIKit/PassKit。
    ///
    /// - Parameters:
    ///   - credentials: 内存凭证持有者。
    ///   - actionHandler: `requiresAction` 分发器。
    /// - Returns: 组装好的控制器。
    func makeController(
        credentials: CredentialStore,
        actionHandler: any ActionHandling
    ) -> CheckoutController {
        makeController(
            paymentService: paymentService,
            cofService: cofService,
            credentials: credentials,
            actionHandler: actionHandler
        )
    }

    /// 为给定服务组装一个 `CheckoutController`（internal DI 缝，显式服务）。
    ///
    /// 依赖以协议注入，便于 mock/real 互换（product-spec 全局约束）。
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
