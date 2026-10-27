import Foundation
import PassKit

/// PassKit 支撑的 `WalletAuthorizing` 具体实现。
///
/// ## 为什么放在 UI 层而不在 Core
/// Core 约束为「不 import UIKit/PassKit」（AGENTS.md §2、Task 9 RULING）。协议
/// `WalletAuthorizing` 与纯函数 `resolveMerchantId` 留在 Core（`Sendable`、无 PassKit），
/// 而 `import PassKit` 连同本具体类型集中放在 UI 层此文件，隔离平台框架依赖。
/// 文件名为 `WalletAuthorizerPassKit.swift`（而非 `WalletAuthorizer.swift`）以避免与 Core
/// 的同名文件在构建系统里冲突（basename 不可重复）。
///
/// ## 单测范围与 Task 14 探针
/// 完整的 `PKPaymentAuthorizationController` 代理流需要真机 + Apple Pay 证书/实体权限，
/// 无法在纯单测环境端到端验证。故此类型保持「薄」：只验证可构造、`canMakePayments()`
/// 可调用；真正的 token 流由 Task 14 的真机探针覆盖。授权成功 ≠ 交易成功
/// （product-spec §3.2）。
///
/// ## 平台与 Swift 6 Sendable 简化说明
/// - SDK 面向 iOS，但 `swift test` 在 macOS 宿主上构建。`PKPaymentAuthorizationControllerDelegate`
///   在 macOS 需要额外的 `presentationWindow(for:)`，其展示路径与 iOS 不同；故完整的
///   `present + 代理` 授权流用 `#if os(iOS)` 限定，macOS 下 `authorize` 直接抛「平台不支持」。
///   `canMakePayments()` 与 `makeRequest()` 两端均可编译并被单测覆盖「可调用 / 可构造」。
/// - `PKPayment` / `PKPaymentToken` 非 `Sendable`。为不让它们穿过并发边界，代理在
///   `@MainActor` 内就把 `payment.token.paymentData` 取出为 `Data`（`Sendable`），
///   仅让 `Data`（或错误）经 continuation 回传。返回的 token `Data` 绝不记录日志（§5）。
struct WalletAuthorizer: WalletAuthorizing {
    /// 设备是否具备 Apple Pay 支付能力。
    ///
    /// 直接代理 `PKPaymentAuthorizationController.canMakePayments()`（设备相关）。
    func canMakePayments() -> Bool {
        PKPaymentAuthorizationController.canMakePayments()
    }

    /// 发起 Apple Pay 授权并返回加密钱包 token 数据。
    ///
    /// 以给定 `merchantId` + `amount` 构造 `PKPaymentRequest`，展示系统授权 sheet，
    /// 授权完成后返回 `PKPayment.token.paymentData`。
    ///
    /// - Parameters:
    ///   - amount: 本次支付金额（最小货币单位）。
    ///   - merchantId: 已解析的 Apple Pay merchant id。
    /// - Returns: 加密钱包 token 的原始 `Data`。
    /// - Throws: 用户取消 / 系统授权失败 / 非 iOS 平台时抛出 `CheckoutError`。
    func authorize(amount: Amount, merchantId: String) async throws -> Data {
        let request = Self.makeRequest(amount: amount, merchantId: merchantId)
        return try await Self.runAuthorization(request)
    }

    // MARK: - 构造（两端可编译）

    /// 由 merchantId + amount 构造 `PKPaymentRequest`。
    ///
    /// 金额以最小货币单位（minor units）换算为十进制展示金额；网络/能力等细节待
    /// 后端确认（Task 14 真机探针对齐）。
    static func makeRequest(amount: Amount, merchantId: String) -> PKPaymentRequest {
        let request = PKPaymentRequest()
        request.merchantIdentifier = merchantId
        request.currencyCode = amount.currencyCode
        request.countryCode = "US"
        request.supportedNetworks = [.visa, .masterCard, .amex]
        request.merchantCapabilities = [.threeDSecure]

        let decimal = Decimal(amount.minorUnits) / Decimal(100)
        request.paymentSummaryItems = [
            PKPaymentSummaryItem(
                label: "Total",
                amount: NSDecimalNumber(decimal: decimal)
            )
        ]
        return request
    }

    // MARK: - 授权运行（iOS 专属代理流）

    #if os(iOS)
    private static func runAuthorization(_ request: PKPaymentRequest) async throws -> Data {
        try await withCheckedThrowingContinuation { continuation in
            Task { @MainActor in
                let controller = PKPaymentAuthorizationController(paymentRequest: request)
                let delegate = AuthorizationDelegate(continuation: continuation)
                controller.delegate = delegate
                // 代理需在授权完成前存活;持有到流程结束。
                delegate.retainController = controller
                controller.present { presented in
                    if !presented {
                        delegate.finish(
                            throwing: CheckoutError(
                                code: "WALLET_PRESENT_FAILED",
                                message: "Failed to present Apple Pay.",
                                category: .runtime,
                                traceId: nil
                            )
                        )
                    }
                }
            }
        }
    }

    /// `PKPaymentAuthorizationController` 代理。
    ///
    /// 在 `@MainActor` 内把非 `Sendable` 的 `PKPayment` 收敛为 `Data` 后再经 continuation
    /// 回传，避免非 `Sendable` 类型穿越并发边界。确保 continuation 只 resume 一次。
    @MainActor
    private final class AuthorizationDelegate: NSObject, PKPaymentAuthorizationControllerDelegate {
        private var continuation: CheckedContinuation<Data, Error>?
        /// 持有 controller 直至授权流结束，避免提前释放。
        var retainController: PKPaymentAuthorizationController?

        init(continuation: CheckedContinuation<Data, Error>) {
            self.continuation = continuation
        }

        func finish(throwing error: Error) {
            continuation?.resume(throwing: error)
            continuation = nil
        }

        private func finish(returning data: Data) {
            continuation?.resume(returning: data)
            continuation = nil
        }

        func paymentAuthorizationController(
            _ controller: PKPaymentAuthorizationController,
            didAuthorizePayment payment: PKPayment,
            handler completion: @escaping (PKPaymentAuthorizationResult) -> Void
        ) {
            // 仅取出 token 数据（Sendable）;不记录任何敏感内容(§5)。
            let tokenData = payment.token.paymentData
            completion(PKPaymentAuthorizationResult(status: .success, errors: nil))
            finish(returning: tokenData)
        }

        func paymentAuthorizationControllerDidFinish(
            _ controller: PKPaymentAuthorizationController
        ) {
            controller.dismiss(completion: nil)
            // 未授权即结束 → 视为用户取消;若已 resume 则为 no-op。
            finish(
                throwing: CheckoutError(
                    code: "WALLET_CANCELED",
                    message: "Apple Pay authorization was canceled.",
                    category: .runtime,
                    traceId: nil
                )
            )
            retainController = nil
        }
    }
    #else
    /// 非 iOS 平台（如 macOS 单测宿主）没有可用的授权展示路径；真机流由 Task 14 覆盖。
    private static func runAuthorization(_ request: PKPaymentRequest) async throws -> Data {
        throw CheckoutError(
            code: "WALLET_UNSUPPORTED_PLATFORM",
            message: "Apple Pay authorization is only available on iOS.",
            category: .runtime,
            traceId: nil
        )
    }
    #endif
}
