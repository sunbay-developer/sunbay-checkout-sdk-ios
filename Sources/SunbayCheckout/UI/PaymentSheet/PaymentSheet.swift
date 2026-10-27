#if canImport(UIKit)
    import UIKit

    /// L1 — 黑盒支付页 `PaymentSheet`（product-spec §2.2）。
    ///
    /// ## 定位
    /// host 以一个 `SunbayCheckout` 入口 + `sessionId`（可选 `customerAccessSecret`）构造本对象，
    /// 调用 `present(from:)` 弹出一个模态支付页；页内自动渲染可用支付方式（新卡表单、Apple Pay 选项、
    /// 以及在 COF 可用时的已保存卡列表），用户完成一次操作后以 `CheckoutOutcome` 解析返回。
    /// 业务编排全在 `CheckoutController`（actor）；本外壳只渲染、转发用户动作、回传结果，不持业务规则。
    ///
    /// ## COF 自动纳入（§2.2）
    /// 当 **同时** 满足「host 传入了 `customerAccessSecret`」且「session `cofEnabled == true`」时，
    /// 页内自动显示已保存卡列表（选卡即付、零验证），新卡仍可勾选保存。可用性裁决权在后端
    /// （`cofEnabled` 下发），客户端自动跟随：无 secret 或后端未开 COF → 退化为仅新卡 + 钱包，
    /// host 无需写任何额外代码。列卡本身永不抛出（`CheckoutController.listSavedCards` 内部降级）。
    ///
    /// ## 可测逻辑 vs. `present()` 包装（拆分说明）
    /// headless xctest 无法稳定地驱动真实 UIKit 展示，故把「start → （按 COF 判定）list → 等待用户动作
    /// → confirm → outcome」的**控制器驱动逻辑**收敛进 internal 可测方法 `runCheckout(seam:)`：
    /// - `seam` 是一个 `async` 闭包，收到 `CheckoutContext`（含已加载 session 与已列出的 saved cards），
    ///   返回用户选择的 `UserAction`（确认新卡 / 选已保存卡 / 钱包 / 取消）。
    /// - `present(from:)` 只是薄 UIKit 包装：构造并展示 `PaymentSheetViewController`，把 VC 的用户动作
    ///   桥接成该 `seam`，再 `await runCheckout` 得到同一套逻辑的 `CheckoutOutcome`，最后收起 VC。
    ///
    /// 单测经 internal 初始化器注入 mock 控制器、直接调用 `runCheckout(seam:)` 并以 `seam` 触发目标
    /// 动作，从而在不触碰真实展示的前提下验证 start/list/confirm/outcome；完整 UI 由示例 app（Task 13）验证。
    ///
    /// ## 安全（§5）
    /// 卡明文只经 `CardInput → CardEncryptor`（在 `CheckoutController.confirmNewCard` 内）加密，
    /// 绝不记录/持久化/回传；`customerAccessSecret` 仅内存持有（`CredentialStore`，终态即清），
    /// 不进入 `CheckoutOutcome`、日志或任何公开返回值。
    ///
    /// 仅 iOS 可用：整体 `#if canImport(UIKit)`；macOS 宿主下不编译（Core 保持 UIKit 无关）。
    public final class PaymentSheet {
        /// 一次 checkout 展示中可供用户选择的动作（由 VC / 测试 seam 产出）。
        ///
        /// internal：仅用于外壳与可测逻辑/测试之间传递用户意图，不对外暴露。
        enum UserAction: Sendable {
            /// 确认一张新卡（可勾选保存 + 同意）。
            case confirmNewCard(CardInput, save: Bool)
            /// 选择一张已保存卡（COF 一键付）。
            case confirmSavedCard(paymentMethodId: String)
            /// Apple Pay 钱包 token 已获取，确认钱包支付。
            case confirmWallet(token: Data)
            /// 用户取消。
            case cancel
        }

        /// 传给 seam 的上下文：已加载 session 与（按 COF 判定后）已列出的 saved cards。
        ///
        /// internal：VC / 测试据此渲染可选项并回传 `UserAction`。
        struct CheckoutContext: Sendable {
            /// 已加载并校验未过期的会话。
            let session: CheckoutSession
            /// 已列出的已保存卡；COF 不可用（无 secret / 未开）时为空。
            let savedCards: [SavedCard]
        }

        // MARK: - 依赖

        /// 支付编排者。public init 经 `SunbayCheckout.makeController` 组装真实实现；
        /// internal init 直接注入（单测用 mock 后端组装的真实 actor）。
        private let controller: CheckoutController
        private let sessionId: String
        /// COF 凭证（可选）；仅内存持有并转交 `CheckoutController.start`，绝不记录/回传（§5）。
        private let customerAccessSecret: String?

        // MARK: - 公共初始化（装配真实依赖）

        /// 以 `SunbayCheckout` 入口与会话标识构造支付页（host 使用的公共入口，§2.2）。
        ///
        /// 通过 `SunbayCheckout.makeController` 缝装配真实的 `CheckoutController`
        /// （注入真实的 `ActionHandler` + `WebAuthOpener` 与内存 `CredentialStore`），
        /// 控制器使用 `checkout` 实例所持有的后端服务（host 注入的或 fail-closed 默认）。
        ///
        /// - Parameters:
        ///   - checkout: SDK 公共入口（持 host 配置与注入的后端服务）。
        ///   - sessionId: 要结账的会话标识。
        ///   - customerAccessSecret: COF 凭证（可选）；host 后端经 HTTPS 下发，仅内存持有、绝不记录。
        public convenience init(
            checkout: SunbayCheckout,
            sessionId: String,
            customerAccessSecret: String? = nil
        ) {
            let controller = checkout.makeController(
                credentials: CredentialStore(),
                actionHandler: ActionHandler(webAuthOpener: WebAuthOpener())
            )
            self.init(
                controller: controller,
                sessionId: sessionId,
                customerAccessSecret: customerAccessSecret
            )
        }

        // MARK: - Internal 初始化（依赖注入缝，供单测用 mock）

        /// 注入预构建控制器的 internal 初始化器（单测经此注入 mock 后端组装的真实 `CheckoutController`）。
        ///
        /// - Parameters:
        ///   - controller: 支付编排者。
        ///   - sessionId: 会话标识。
        ///   - customerAccessSecret: COF 凭证（可选）。
        init(
            controller: CheckoutController,
            sessionId: String,
            customerAccessSecret: String? = nil
        ) {
            self.controller = controller
            self.sessionId = sessionId
            self.customerAccessSecret = customerAccessSecret
        }

        // MARK: - 公共 API

        /// 弹出支付页并等待用户完成一次操作（§2.2）。
        ///
        /// 薄 UIKit 包装：构造 `PaymentSheetViewController`，由 `runCheckout(seam:)` 驱动
        /// start → （COF 判定后）list → 展示 VC → 等待用户动作 → confirm → outcome；完成后收起 VC。
        /// 返回**单次**展示结果；`pending/unknown` 需配合 `retrievePayment()` 或服务端对账。
        ///
        /// - Parameter presenter: 用于 modally 展示支付页的 host 视图控制器。
        /// - Returns: 本次展示的 `CheckoutOutcome`（用户取消 → `.canceled`）。
        @MainActor
        public func present(from presenter: UIViewController) async -> CheckoutOutcome {
            // VC 持有者：用于在 runCheckout 的 seam 阶段展示它、并桥接其用户动作。
            var viewController: PaymentSheetViewController?

            let outcome = await runCheckout { [weak presenter] context in
                // 在主线程构造并展示 VC，把其用户动作作为本次 seam 的结果 await 出来。
                await withCheckedContinuation { (continuation: CheckedContinuation<UserAction, Never>) in
                    Task { @MainActor in
                        let vc = PaymentSheetViewController(
                            session: context.session,
                            savedCards: context.savedCards
                        )
                        viewController = vc
                        vc.onAction = { action in
                            continuation.resume(returning: action)
                        }
                        vc.modalPresentationStyle = .formSheet
                        if let presenter {
                            presenter.present(vc, animated: true)
                        } else {
                            // 无 presenter（异常）→ 视为取消，避免悬挂。
                            continuation.resume(returning: .cancel)
                        }
                    }
                }
            }

            // 收起 VC（若已展示）。
            await MainActor.run {
                viewController?.dismiss(animated: true)
            }
            return outcome
        }

        /// 独立于 UI 的结果查询（崩溃/被杀恢复，§2.2 / §4.3）。委派控制器。
        ///
        /// - Returns: 最新的 `PaymentSnapshot`。
        /// - Throws: 查询失败透传。
        public func retrievePayment() async throws -> PaymentSnapshot {
            try await controller.retrievePayment(sessionId: sessionId)
        }

        // MARK: - Internal 可测逻辑（控制器驱动）

        /// 驱动一次 checkout 的可测核心逻辑（不触碰真实 UIKit 展示）。
        ///
        /// 流程：
        /// 1. `controller.start(sessionId:customerAccessSecret:)` 加载并校验会话；加载失败 → `.canceled`
        ///    之外的失败由 start 抛出，这里兜底映射为 `.unknown`/`.failed`（见下）。
        /// 2. **COF 自动纳入**：`customerAccessSecret != nil && session.cofEnabled` 时调用
        ///    `controller.listSavedCards()`（内部降级、永不抛出）；否则不驱动列卡、savedCards 为空。
        /// 3. 以 `CheckoutContext` 调用 `seam`，拿到用户 `UserAction`。
        /// 4. 按动作驱动对应 `controller.confirm*`；`.cancel` → `.canceled`。
        ///
        /// - Parameter seam: 收到上下文、返回用户动作的 async 闭包（`present` 以 VC 实现；测试直接提供）。
        /// - Returns: 本次 checkout 的 `CheckoutOutcome`。
        func runCheckout(
            seam: @Sendable (CheckoutContext) async -> UserAction
        ) async -> CheckoutOutcome {
            // 1. 加载会话。
            let session: CheckoutSession
            do {
                session = try await controller.start(
                    sessionId: sessionId,
                    customerAccessSecret: customerAccessSecret
                )
            } catch let error as CheckoutError {
                return .failed(txnId: nil, error: error)
            } catch {
                return .unknown(sessionId: sessionId)
            }

            // 2. COF 自动纳入判定（§2.2）：有 secret 且后端开启 COF → 列卡；否则不列。
            let savedCards: [SavedCard]
            if customerAccessSecret != nil && session.cofEnabled {
                savedCards = await controller.listSavedCards()
            } else {
                savedCards = []
            }

            // 3. 等待用户动作。
            let action = await seam(CheckoutContext(session: session, savedCards: savedCards))

            // 4. 驱动确认路径。
            switch action {
            case let .confirmNewCard(input, save):
                // 勾选保存时附带同意（§7.3；COF 保存需 consent）。
                let consent = save ? Consent(version: "1.0") : nil
                return await controller.confirmNewCard(input, save: save, consent: consent)
            case let .confirmSavedCard(paymentMethodId):
                return await controller.confirmSavedCard(paymentMethodId: paymentMethodId)
            case let .confirmWallet(token):
                return await controller.confirmWallet(token: token)
            case .cancel:
                await controller.dismiss()
                return .canceled
            }
        }
    }
#endif
