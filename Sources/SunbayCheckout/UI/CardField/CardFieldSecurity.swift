#if canImport(UIKit)
    import UIKit

    /// 卡输入控件(PAN / 有效期 / CVV)的**统一安全配置**,集中在此一处。
    ///
    /// 实现 security-and-pci.md §3 item 2 与 §3.1、product-spec §5.3.1 的按字段规格:
    /// - 三个字段统一关闭自动纠错 / 拼写检查 / smart 系列(破折号、引号、插入删除),
    ///   并使用 `.asciiCapableNumberPad`,防止明文进入键盘自学习词典 / QuickType 缓存。
    /// - PAN:`textContentType = .creditCardNumber`,启用系统扫卡 / 自动填充
    ///   (Apple 官方认可的安全通道)。
    /// - CVV:`textContentType = nil`,**绝不进自动填充 / 系统记忆**;额外开启
    ///   `isSecureTextEntry`(防窥屏;spec 允许 CVV 安全输入)。
    /// - 有效期:数字键盘 + 关纠错,无特殊 contentType。
    ///
    /// 本类型**不触碰卡明文**,只配置 `UITextField` 的键盘 / 填充 / 缓存行为;
    /// 明文始终只在字段内与装配出的 `CardInput` 中流转(见 §4 敏感数据边界)。
    ///
    /// 仅 iOS 可用:`UITextField` 属 UIKit,整体以 `#if canImport(UIKit)` 限定,
    /// macOS 宿主(`swift test`)下不编译。真机验证由示例 App(Task 13)覆盖。
    enum CardFieldSecurity {
        /// 对三个卡字段套用统一安全配置。
        ///
        /// - Parameters:
        ///   - pan: 卡号输入框(PAN)。
        ///   - expiry: 有效期输入框。
        ///   - cvv: 安全码输入框(CVV/CVC)。
        static func apply(toPAN pan: UITextField, expiry: UITextField, cvv: UITextField) {
            // 三字段共同的「关键盘自学习 / 联想 / smart」基线。
            for field in [pan, expiry, cvv] {
                field.autocorrectionType = .no
                field.spellCheckingType = .no
                field.smartDashesType = .no
                field.smartQuotesType = .no
                field.smartInsertDeleteType = .no
                field.keyboardType = .asciiCapableNumberPad
            }

            // PAN:允许系统扫卡 / 自动填充(Apple 官方安全通道)。
            pan.textContentType = .creditCardNumber

            // CVV:绝不被系统记忆 / 自动填充;并开启安全输入防窥屏。
            cvv.textContentType = nil
            cvv.isSecureTextEntry = true

            // 有效期:仅数字键盘 + 关纠错(基线已覆盖),无特殊 contentType。
            expiry.textContentType = nil
        }
    }
#endif
