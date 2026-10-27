/// 内存持有敏感凭证(customerAccessSecret / checkoutClientSecret)的内聚边界。
///
/// 安全约束(见 `docs/security-and-pci.md` §3 item 3/7、§4):
/// - **仅内存持有**:单个可选 `String` 属性,绝不写入 UserDefaults / 文件 / Keychain / 剪贴板。
/// - **零日志泄漏**:绝不 print / os_log / 埋点 / 崩溃上报任何 secret 值。
/// - **终态即清**:`clear()` 在交易到达终态或 dismiss 时由上层调用,幂等。
///
/// `actor` 隔离保证并发访问下的互斥;内部不可见,不对外暴露(非 `public`)。
actor CredentialStore {
    /// 当前持有的 secret;`nil` 表示未持有或已清除。仅内存。
    private var secret: String?

    init() {}

    /// 持有一个 secret(覆盖已有值)。
    /// - Parameter customerAccessSecret: 短 TTL 的凭证值;仅内存持有,不落盘不记日志。
    func hold(customerAccessSecret: String) {
        secret = customerAccessSecret
    }

    /// 读取当前持有的 secret。
    /// - Returns: 已持有则返回其值,否则 `nil`。
    func current() -> String? {
        secret
    }

    /// 清除当前持有的 secret。幂等:已为空时重复调用安全无副作用。
    func clear() {
        secret = nil
    }
}
