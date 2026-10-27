import Foundation

/// Apple Pay（钱包）授权能力的 UI 无关抽象。
///
/// ## 分层与 PassKit 边界（见 AGENTS.md §2、Task 9 RULING）
/// Core 到目前为止不 import 任何 UIKit/PassKit。PassKit 虽非 UIKit，但为保持
/// 「Core 与 UI/平台框架无关」的约束，这里**只在 Core 放置协议**（`Sendable`、不 import
/// PassKit），供 `CheckoutController` 等后续任务依赖注入；**PassKit 支撑的具体实现**
/// `struct WalletAuthorizer` 连同 `import PassKit` 放在 UI 层
/// `Sources/SunbayCheckout/UI/Wallet/WalletAuthorizerPassKit.swift`（UI 层可 import
/// PassKit；文件名加 `PassKit` 后缀以避免与本 Core 文件 basename 冲突）。
///
/// 钱包授权成功 ≠ 交易成功；只有后端确认的终态才算（product-spec §3.2）。
protocol WalletAuthorizing: Sendable {
    /// 设备是否具备 Apple Pay 支付能力（设备相关）。
    func canMakePayments() -> Bool

    /// 发起钱包授权并返回加密钱包 token 数据（`PKPayment.token.paymentData`）。
    ///
    /// - Parameters:
    ///   - amount: 本次支付金额。
    ///   - merchantId: 已解析的 Apple Pay merchant id（见 `resolveMerchantId`）。
    /// - Returns: 加密钱包 token 的原始 `Data`（绝不记录日志，§5）。
    /// - Throws: 授权被取消 / 失败时抛出。
    func authorize(amount: Amount, merchantId: String) async throws -> Data
}

/// 解析最终使用的 Apple Pay merchant id：host 配置优先于 session 下发。
///
/// 两种 merchant-id 模型走同一条代码路径；host 的 `CheckoutConfiguration.applePayMerchantId`
/// 若存在则胜出，否则回退到 session 下发的 id（product-spec §2.1 / §3.2 / §7）。
///
/// 该函数为纯函数且不 import PassKit，故放在 Core 与协议同处，便于**脱离 PassKit** 单测。
///
/// - Parameters:
///   - configured: host 通过 `CheckoutConfiguration` 配置的 merchant id（可空）。
///   - sessionProvided: 后端 session 下发的 merchant id（可空）。
/// - Returns: 解析后的 merchant id；两者皆空时为 nil。
func resolveMerchantId(configured: String?, sessionProvided: String?) -> String? {
    configured ?? sessionProvided
}
