#if canImport(UIKit)
    import UIKit

    /// 收集 PAN / 有效期 / CVV 的原生卡输入控件。
    ///
    /// ## 职责边界
    /// `CardField` 只做两件事:
    /// 1. 持有三个 `UITextField`,在 `init` 时调用 `CardFieldSecurity.apply(...)`
    ///    套用统一安全配置(见 `CardFieldSecurity` / security-and-pci.md §3.1)。
    /// 2. 以 `cardInput` 暴露装配好的 `CardInput`。
    ///
    /// 它**不加密、不校验业务规则、不记录 / 持久化**任何卡数据。加密是
    /// `CardEncryptor` 的唯一职责(AGENTS.md §2、Global Constraints);本控件
    /// 只在字段与返回的 `CardInput` 中临时承载明文,交给上层(Task 12 PaymentSheet)
    /// 后应尽快丢弃。明文绝不写日志 / 持久化(§4 敏感数据边界)。
    ///
    /// ## 校验范围(最小)
    /// `cardInput` 仅在四个字段去除首尾空白后**均非空**时返回非 `nil`;
    /// 更严格的卡号 / 有效期校验留给后续任务 / 后端。有效期以 `MM/YY` 或 `MM/YYYY`
    /// 形式录入,这里按 `/` 拆分为月 / 年交给 `CardInput`;拆不出时视为无效(返回 `nil`)。
    ///
    /// 仅 iOS 可用:整体以 `#if canImport(UIKit)` 限定,macOS 宿主下不编译。
    /// 本任务为 internal;是否公开由 Task 12 决定。
    final class CardField: UIView {
        /// 卡号(PAN)输入框。
        let panField = UITextField()
        /// 有效期输入框(录入形如 `MM/YY`)。
        let expiryField = UITextField()
        /// 安全码(CVV/CVC)输入框。
        let cvvField = UITextField()

        /// 竖直排列三个输入框的容器。
        private let stack = UIStackView()

        override init(frame: CGRect) {
            super.init(frame: frame)
            configure()
        }

        required init?(coder: NSCoder) {
            super.init(coder: coder)
            configure()
        }

        /// 套用安全配置并做最简布局。
        private func configure() {
            CardFieldSecurity.apply(toPAN: panField, expiry: expiryField, cvv: cvvField)

            panField.placeholder = "Card number"
            expiryField.placeholder = "MM/YY"
            cvvField.placeholder = "CVV"

            stack.axis = .vertical
            stack.spacing = 8
            stack.translatesAutoresizingMaskIntoConstraints = false
            stack.addArrangedSubview(panField)
            stack.addArrangedSubview(expiryField)
            stack.addArrangedSubview(cvvField)
            addSubview(stack)

            NSLayoutConstraint.activate([
                stack.topAnchor.constraint(equalTo: topAnchor),
                stack.leadingAnchor.constraint(equalTo: leadingAnchor),
                stack.trailingAnchor.constraint(equalTo: trailingAnchor),
                stack.bottomAnchor.constraint(equalTo: bottomAnchor),
            ])
        }

        /// 当前装配出的卡明文输入;字段齐全时返回 `CardInput`,否则 `nil`。
        ///
        /// 齐全的定义(最小校验):PAN、有效期月、有效期年、CVV 去空白后均非空。
        /// 有效期按 `/` 拆分为「月 / 年」;无法拆出两段非空值时返回 `nil`。
        /// 返回的 `CardInput` 承载明文,调用方用后即弃,不得记录 / 持久化。
        var cardInput: CardInput? {
            let pan = (panField.text ?? "").trimmingCharacters(in: .whitespaces)
            let cvv = (cvvField.text ?? "").trimmingCharacters(in: .whitespaces)
            let expiry = (expiryField.text ?? "").trimmingCharacters(in: .whitespaces)

            guard !pan.isEmpty, !cvv.isEmpty, !expiry.isEmpty else { return nil }

            let parts = expiry.split(separator: "/", maxSplits: 1, omittingEmptySubsequences: false)
            guard parts.count == 2 else { return nil }
            let month = parts[0].trimmingCharacters(in: .whitespaces)
            let year = parts[1].trimmingCharacters(in: .whitespaces)
            guard !month.isEmpty, !year.isEmpty else { return nil }

            return CardInput(
                cardNumber: pan,
                expiryMonth: month,
                expiryYear: year,
                cvv: cvv
            )
        }
    }
#endif
