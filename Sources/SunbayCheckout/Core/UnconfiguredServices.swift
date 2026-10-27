import Foundation

/// 「未配置」的 fail-closed 默认服务（internal，共享）。
///
/// ## 为什么存在
/// 公共 `SunbayCheckout(configuration:)`（朴素 init）不接收任何后端服务；但 UI 外壳
/// 与内部缝仍需要一对 `PaymentService` / `CofService` 才能组装 `CheckoutController`。
/// 真实后端适配器尚未落地（后端契约未定，product-spec §7/§8），SDK 也**不**自带 HTTP 适配器。
///
/// 因此当 host 未经 `SunbayCheckout(configuration:paymentService:cofService:)` 注入服务时，
/// 默认使用这对占位实现：对所有调用**fail-closed**，抛 `NETWORK_UNAVAILABLE`（绝不静默成功，
/// 不用空结果掩盖未配置）。其存在只为让公共 API 形态成立并可编译，不改变任何对外符号。
///
/// 这两个类型从 ApplePayButton 迁出到此共享位置（Task 11.5），使「朴素 init 的默认」与
/// 「ApplePayButton 的回退」用同一份 fail-closed 实现。它们不 import 任何 UIKit/PassKit，
/// 因此在 macOS host 上也可用（Core 约束，AGENTS.md §2.6）。

/// 未配置时抛出的统一错误（`NETWORK_UNAVAILABLE`，不含任何敏感信息）。
private func unconfiguredServiceError() -> CheckoutError {
    CheckoutError(
        code: "NETWORK_UNAVAILABLE",
        message: "No backend adapter is configured for this SDK build.",
        category: .network,
        traceId: nil
    )
}

/// 「未配置」的 `PaymentService` 占位实现（internal，fail-closed）。
struct UnconfiguredPaymentService: PaymentService {
    init() {}
    func loadSession(_ id: String) async throws -> CheckoutSession { throw unconfiguredServiceError() }
    func submit(_ req: SubmitRequest) async throws -> PaymentSnapshot { throw unconfiguredServiceError() }
    func getResult(sessionId: String) async throws -> PaymentSnapshot { throw unconfiguredServiceError() }
}

/// 「未配置」的 `CofService` 占位实现（internal，fail-closed）。
struct UnconfiguredCofService: CofService {
    init() {}
    func listPaymentMethods(
        customerAccessSecret: String,
        sessionId: String
    ) async throws -> [SavedCard] {
        throw unconfiguredServiceError()
    }
}
