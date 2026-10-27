#if canImport(UIKit)
    import UIKit

    /// 独立的 Apple Pay 按钮（L3，product-spec §2.3）。
    ///
    /// ## 定位
    /// 长期存在的 UIKit 控件：host 把它放进自己的界面，用户点击即发起 Apple Pay。它只用 Core 的
    /// `WalletAuthorizing` + `CheckoutController` 两个能力，**不碰卡表单、不持有业务规则**
    /// （业务编排全在 `CheckoutController`）。事件用闭包回调（iOS 惯例、持续事件源，§2.5），
    /// 而非一次性 async 返回。
    ///
    /// ## 可用性（isAvailable）
    /// `可用 = 后端允许 ∩ 设备可用 ∩ merchant-id 已配置`：
    /// - **设备可用**：`WalletAuthorizing.canMakePayments()`（设备相关，构造时即可知）。
    /// - **merchant-id 已配置**：`resolveMerchantId(configured:sessionProvided:)` 非 nil
    ///   （host 配置优先于 session 下发；构造时即可知）。
    /// - **后端允许**：`CheckoutController` 加载 session 后，其 `methods` 是否含 `.applePay`
    ///   （**异步**，session 加载完成后才可知）。
    ///
    /// 构造时先以「后端允许=false」给出初值；随后在后台加载 session，加载完成后重算可用性，
    /// 若发生变化则在主线程触发 `onAvailabilityChange`。
    ///
    /// ## 结果（onResult）
    /// 点击 → `WalletAuthorizing.authorize(...)` 取加密钱包 token → `controller.confirmWallet(token:)`
    /// → 后端确认终态映射为 `CheckoutOutcome` → 在主线程触发 `onResult`。钱包授权成功 ≠ 交易成功
    /// （§3.2）：真正结论来自 `confirmWallet` 的 outcome。
    ///
    /// ## 安全（§5）
    /// 钱包 token `Data` 只经 `authorize → confirmWallet` 这一条路径流动，**绝不**进入
    /// `onResult`、日志或任何持久化。被取消 / 授权失败时不产生 `onResult`（保持控件可再次点击）。
    ///
    /// 仅 iOS 可用：整体 `#if canImport(UIKit)`；macOS 宿主下不编译。
    public final class ApplePayButton: UIControl {
        /// 按钮配色风格（跟随浅/深色方案；保持最小）。
        public enum ApplePayButtonStyle: Sendable {
            /// 跟随当前 trait（浅色→黑底、深色→白底）。
            case automatic
            /// 固定黑底白字。
            case black
            /// 固定白底黑字（带描边）。
            case white
        }

        // MARK: - 公共事件（闭包，持续事件源，§2.5）

        /// 可用性发生变化时回调（在主线程）。携带最新的 `isAvailable`。
        public var onAvailabilityChange: ((Bool) -> Void)?

        /// 一次点击的支付结果回调（在主线程）。携带后端确认的 `CheckoutOutcome`。
        public var onResult: ((CheckoutOutcome) -> Void)?

        /// 当前是否可用（见类型说明的三因素交集）。只读。
        public private(set) var isAvailable: Bool {
            didSet {
                guard oldValue != isAvailable else { return }
                let available = isAvailable
                onMain { [weak self] in
                    self?.isEnabled = available
                    self?.onAvailabilityChange?(available)
                }
            }
        }

        // MARK: - 依赖（经 internal init 注入；public init 装配真实实现）

        private let controller: CheckoutController
        private let walletAuthorizer: any WalletAuthorizing
        private let sessionId: String
        /// 本次支付金额；session 加载完成后以 session 金额覆盖（构造时可为占位 nil）。
        private var amount: Amount?
        /// 已解析的 Apple Pay merchant id（host 配置优先）；nil 表示未配置 → 不可用。
        private let resolvedMerchantId: String?

        /// 设备是否可用（构造时固定）。
        private let deviceCapable: Bool
        /// 后端是否允许 Apple Pay（session 加载后更新）。
        private var backendAllowed = false

        // MARK: - 公共初始化（装配真实依赖）

        /// 以 `SunbayCheckout` 入口与会话标识构造按钮（host 使用的公共入口）。
        ///
        /// 通过 `SunbayCheckout.makeController` 缝装配真实的 `CheckoutController`
        /// （注入真实的 `ActionHandler` + `WebAuthOpener`），并以真实的 PassKit
        /// `WalletAuthorizer` 作为钱包能力。merchant-id 取 host 配置（优先）或 session 下发。
        ///
        /// - Parameters:
        ///   - checkout: SDK 公共入口（持 host 配置）。
        ///   - sessionId: 要结账的会话标识。
        ///   - style: 按钮配色风格;缺省 `.automatic`。
        ///
        /// - Note: 控制器使用 `checkout` 实例所持有的后端服务：host 若经
        ///   `SunbayCheckout(configuration:paymentService:cofService:)` 注入了真实/mock 服务，
        ///   则按钮使用它们；否则回退到共享的 fail-closed `Unconfigured*` 默认（§7/§8 契约未定前）。
        public convenience init(
            checkout: SunbayCheckout,
            sessionId: String,
            style: ApplePayButtonStyle = .automatic
        ) {
            let webAuthOpener = WebAuthOpener()
            let controller = checkout.makeController(
                credentials: CredentialStore(),
                actionHandler: ActionHandler(webAuthOpener: webAuthOpener)
            )
            self.init(
                controller: controller,
                walletAuthorizer: WalletAuthorizer(),
                sessionId: sessionId,
                configuredMerchantId: checkout.configuration.applePayMerchantId,
                amount: nil,
                style: style
            )
        }

        // MARK: - Internal 初始化（依赖注入缝，供单测用 mock）

        /// 注入依赖的 internal 初始化器（单测经此注入 mock 控制器与 mock 钱包能力）。
        ///
        /// - Parameters:
        ///   - controller: 支付编排者（可由 mock 后端组装的真实 actor）。
        ///   - walletAuthorizer: 钱包能力（设备可用性 + 授权取 token）。
        ///   - sessionId: 会话标识。
        ///   - configuredMerchantId: host 配置的 merchant id（可空）。
        ///   - amount: 本次金额；缺省 nil，session 加载后以 session 金额覆盖。
        ///   - style: 配色风格。
        init(
            controller: CheckoutController,
            walletAuthorizer: any WalletAuthorizing,
            sessionId: String,
            configuredMerchantId: String?,
            amount: Amount? = nil,
            style: ApplePayButtonStyle = .automatic
        ) {
            self.controller = controller
            self.walletAuthorizer = walletAuthorizer
            self.sessionId = sessionId
            self.amount = amount
            // session 不下发 merchant id（Core 模型不含该字段）→ sessionProvided 传 nil。
            self.resolvedMerchantId = resolveMerchantId(
                configured: configuredMerchantId,
                sessionProvided: nil
            )
            self.deviceCapable = walletAuthorizer.canMakePayments()
            self.isAvailable = false // 后端允许未知前先不可用。

            super.init(frame: .zero)

            configureAppearance(style)
            addTarget(self, action: #selector(handleTap), for: .touchUpInside)
            // 初值：后端允许尚未知 → 不可用。
            isEnabled = false

            // 后台加载 session,完成后重算可用性。
            Task { [weak self] in
                await self?.loadSessionAndRefreshAvailability()
            }
        }

        @available(*, unavailable)
        required init?(coder: NSCoder) {
            fatalError("init(coder:) is not supported; use init(checkout:sessionId:style:)")
        }

        // MARK: - 可用性计算

        /// 加载 session 并刷新可用性（后台）。
        ///
        /// 加载成功 → `backendAllowed = methods.contains(.applePay)`，并以 session 金额覆盖
        /// 本次支付金额;加载失败 → 保持后端允许=false（不可用）。随后重算并（变化时）回调。
        private func loadSessionAndRefreshAvailability() async {
            do {
                let session = try await controller.start(
                    sessionId: sessionId,
                    customerAccessSecret: nil
                )
                backendAllowed = session.methods.contains(.applePay)
                amount = session.amount
            } catch {
                backendAllowed = false
            }
            recomputeAvailability()
        }

        /// 以三因素交集重算 `isAvailable`（其 `didSet` 负责在变化时主线程回调）。
        private func recomputeAvailability() {
            isAvailable = deviceCapable && backendAllowed && (resolvedMerchantId != nil)
        }

        // MARK: - 点击 → 授权 → 确认

        /// 处理点击：授权取 token → `confirmWallet` → 主线程回调 `onResult`。
        @objc private func handleTap() {
            guard isAvailable, let merchantId = resolvedMerchantId, let amount else { return }
            let authorizer = walletAuthorizer
            let controller = controller
            Task { [weak self] in
                let outcome: CheckoutOutcome
                do {
                    // 钱包 token:只在 authorize → confirmWallet 间流动,绝不进 onResult/日志(§5)。
                    let token = try await authorizer.authorize(
                        amount: amount,
                        merchantId: merchantId
                    )
                    outcome = await controller.confirmWallet(token: token)
                } catch {
                    // 授权被取消 / 失败:不产生交易结论,控件保持可再次点击。
                    return
                }
                self?.onMain { self?.onResult?(outcome) }
            }
        }

        // MARK: - 外观

        /// 套用最小配色（跟随浅/深色方案）。不硬编码业务色;仅本控件自身视觉。
        private func configureAppearance(_ style: ApplePayButtonStyle) {
            layer.cornerRadius = 8
            let (bg, fg): (UIColor, UIColor)
            switch style {
            case .black:
                (bg, fg) = (.black, .white)
            case .white:
                (bg, fg) = (.white, .black)
                layer.borderWidth = 1
                layer.borderColor = UIColor.separator.cgColor
            case .automatic:
                // 跟随 trait:深色→白底黑字,浅色→黑底白字(label/systemBackground 自动适配)。
                (bg, fg) = (.label, .systemBackground)
            }
            backgroundColor = bg
            tintColor = fg
        }

        // MARK: - 主线程工具

        /// 在主线程执行闭包（已在主线程则同步执行，避免多余一跳）。
        private func onMain(_ work: @escaping () -> Void) {
            if Thread.isMainThread {
                work()
            } else {
                DispatchQueue.main.async(execute: work)
            }
        }
    }
#endif
