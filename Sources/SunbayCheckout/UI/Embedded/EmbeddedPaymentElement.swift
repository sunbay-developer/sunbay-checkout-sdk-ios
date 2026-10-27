import Foundation

/// L2, planned v2 — not part of the public API.
///
/// 预留的嵌入式支付元素占位符（product-spec §2.6）。L2「嵌入式结账元素」计划在 v2 版本提供，
/// 届时将以内联 UI 的形式嵌入 host 自己的页面（区别于 L1 `PaymentSheet` 的黑盒全屏/模态页）。
///
/// 本任务（Task 12）只**保留名称与目录**：
/// - 刻意保持 **internal**（非 `public`）——它不是当前公共 API 的一部分，不对 host 暴露；
///   公共 API 审计（Final verification）据此校验它未被误标 `public`。
/// - 不含任何行为/UI 依赖，因此无需 UIKit，可为纯 Swift；待 v2 真正实现时再引入 `#if canImport(UIKit)`。
///
/// - Warning: 不要在本类型上添加公共成员或将其标为 `public`；它是预留占位，真实实现见后续 v2 计划。
struct EmbeddedPaymentElement {
    /// 预留的无参初始化器（占位）。v2 实现将以 `SunbayCheckout` + `sessionId` 等依赖替换。
    init() {}
}
