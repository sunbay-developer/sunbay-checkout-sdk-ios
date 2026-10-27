import Foundation

/// 已保存卡(COF)后端能力契约(UI 无关)。
///
/// 对应 product-spec §7.5(列卡)。使用 `customerAccessSecret`(Customer Grant)+ `sessionId`
/// 直连 PSP;作用域从凭证推导,不接受客户端 customerId。未授权返回 403,不得用空列表掩盖。
///
/// - Note: 自 Task 11.5 起**公开**：host 通过 `SunbayCheckout` 注入自实现以支持 COF 列卡。
public protocol CofService: Sendable {
    /// 列出当前 Customer 在本会话下可用的已保存卡。
    ///
    /// - Parameters:
    ///   - customerAccessSecret: Customer Grant 凭证(仅内存持有,见 §7.6)。
    ///   - sessionId: 会话标识。
    /// - Returns: 已保存卡展示信息列表。
    func listPaymentMethods(customerAccessSecret: String, sessionId: String) async throws -> [SavedCard]
}
