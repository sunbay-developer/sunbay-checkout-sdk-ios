import Foundation

/// 可选的「R 快照→动作」查询缝(seam)。
///
/// ## 为什么需要这个 seam
/// Task 2 的 `PaymentSnapshot` 刻意只承载 `sessionId / status / txnId`,不含 `action`;
/// Task 3 的 `PaymentService.submit / getResult` 也只返回 `PaymentSnapshot`。但 §4.5 要求
/// 在 `txnStatus == "R"`(requiresAction)时把 `PaymentAction` 交给 `ActionHandling` 分发。
///
/// 为在**不修改** Task 2 的 `PaymentSnapshot`、也**不改动** Task 3 的 `PaymentService` 协议签名的
/// 前提下让控制器拿到动作,这里引入一个**可选**协议:`PaymentService` 的具体实现**可以**额外
/// 遵循它,返回「最近一次返回 R 快照时对应的 `PaymentAction`」。控制器通过
/// `paymentService as? PaymentActionProviding` 探测:
/// - 实现了 → 取其返回的动作(无则按 `.unknown` 处理);
/// - 未实现 → 没有动作信息可用,按 `.unknown` 兜底(交由 `ActionHandling` 映射为不支持)。
///
/// 真实适配器(后端 ready 后)可在内部先用 `ContractDecoding.decodeResult` 得到
/// `ResultEnvelope { snapshot, action }`,把 `snapshot` 从 `submit/getResult` 返回,同时实现本协议
/// 暴露 `action`——契约与现有 `ResultEnvelope` 完全一致,无需改动既有类型。
protocol PaymentActionProviding: Sendable {
    /// 返回最近一次 `R`(requiresAction)快照对应的进一步动作;无则 nil。
    func actionForLatestRequiresAction() -> PaymentAction?
}

/// Core 内部使用的 `CheckoutError` 工厂。
///
/// 集中构造本任务需要的少量错误,保证 code / category 稳定一致(见 §7.7 的 code 约定)。
/// 不携带任何敏感数据(§5)。
enum CheckoutErrors {
    /// 已有一个 checkout 在途(单活跃会话不变量,§4.2)。
    static func alreadyPresenting() -> CheckoutError {
        CheckoutError(
            code: "ALREADY_PRESENTING",
            message: "A checkout is already in progress.",
            category: .runtime,
            traceId: nil
        )
    }

    /// 网络不可用 / 提交或查询失败。
    static func networkUnavailable() -> CheckoutError {
        CheckoutError(
            code: "NETWORK_UNAVAILABLE",
            message: "The network is unavailable.",
            category: .network,
            traceId: nil
        )
    }

    /// 会话无效 / 已过期。
    static func sessionExpired() -> CheckoutError {
        CheckoutError(
            code: "CHECKOUT_EXPIRED",
            message: "The checkout session has expired.",
            category: .validation,
            traceId: nil
        )
    }

    /// 支付失败(由终态 `F` 映射;后端未给出更细原因时的兜底)。
    static func paymentFailed() -> CheckoutError {
        CheckoutError(
            code: "PAYMENT_FAILED",
            message: "The payment failed.",
            category: .payment,
            traceId: nil
        )
    }

    /// 本地卡加密失败(新卡路径,缺少公钥或加密错误)。
    static func encryptionFailed() -> CheckoutError {
        CheckoutError(
            code: "CARD_ENCRYPTION_FAILED",
            message: "Failed to prepare card data.",
            category: .runtime,
            traceId: nil
        )
    }
}

/// 唯一的 UI 无关支付编排者(product-spec §1 / §4)。
///
/// 三条支付路径(新卡 / Apple Pay / COF 已保存卡)共享同一状态机、幂等键、结果去重与
/// 「提交失败先查询」逻辑。`actor` 隔离天然串行化,免去手写锁即可满足并发不变量(§4.2)。
///
/// 依赖全部为协议注入(`PaymentService` / `CofService` / `ActionHandling`)+ 内聚边界
/// (`CredentialStore` 持 secret、`CardEncryptor` 碰明文卡)。本类不 import 任何 UIKit/PassKit
/// (Core UI 无关,AGENTS.md §2.6)。
actor CheckoutController {
    private let paymentService: any PaymentService
    private let cofService: any CofService
    private let credentials: CredentialStore
    private let actionHandler: any ActionHandling

    /// pending(`I`)→ 终态的结果轮询器(§4.4)。
    ///
    /// 可注入(测试用零等待 sleep 使轮询确定且不真正休眠);未注入时用同一 `paymentService`
    /// 以默认参数构造,保证生产路径无需显式传入即可工作。
    private let poller: ResultPoller

    /// 当前已加载的会话;`start` 成功后写入。
    private var session: CheckoutSession?

    /// 单活跃会话守卫(§4.2):非 nil 表示有一次 confirm 在途。
    ///
    /// 任一 confirm 进入时在 actor 隔离域内检查并占用;第二次进入发现已占用 → 立即返回
    /// `alreadyPresenting`,**不**生成新 attemptId、**不**调用 submit。
    private var activeAttempt: UUID?

    /// 创建控制器。
    ///
    /// - Parameters:
    ///   - paymentService: 支付后端能力(mock/real 可换)。
    ///   - cofService: 已保存卡列卡能力。
    ///   - credentials: 内存凭证持有者(终态即清)。
    ///   - actionHandler: `requiresAction` 分发器(Task 8 提供真实实现)。
    ///   - poller: pending→终态结果轮询器(可选)。缺省时用同一 `paymentService` 以 `.default`
    ///     参数构造;测试可注入零等待 sleep 的 poller 以确定性地驱动 pending 轮询。
    init(
        paymentService: any PaymentService,
        cofService: any CofService,
        credentials: CredentialStore,
        actionHandler: any ActionHandling,
        poller: ResultPoller? = nil
    ) {
        self.paymentService = paymentService
        self.cofService = cofService
        self.credentials = credentials
        self.actionHandler = actionHandler
        self.poller = poller ?? ResultPoller(service: paymentService)
    }

    // MARK: - 生命周期

    /// 加载会话并开始一次 UI 结账。
    ///
    /// 若提供 `customerAccessSecret`,先内存持有(COF);随后加载会话并校验未过期。
    ///
    /// - Parameters:
    ///   - sessionId: 会话标识。
    ///   - customerAccessSecret: COF 凭证(可选);仅内存持有,终态/关闭即清。
    /// - Returns: 加载到的会话。
    /// - Throws: 加载失败透传;会话已过期抛出 `CheckoutError`(`.validation`)。
    func start(sessionId: String, customerAccessSecret: String?) async throws -> CheckoutSession {
        if let secret = customerAccessSecret {
            await credentials.hold(customerAccessSecret: secret)
        }

        let loaded = try await paymentService.loadSession(sessionId)

        // 校验未过期(§3.1:校验 session 有效/未过期)。
        guard loaded.expiresAt > Date() else {
            // 过期即清凭证(§4.2 终态/关闭/过期即清)。
            await credentials.clear()
            throw CheckoutErrors.sessionExpired()
        }

        session = loaded
        return loaded
    }

    /// 列出已保存卡(COF)。
    ///
    /// 降级规则(§2.2 / Task 6):`cofEnabled == false` → 直接返回 `[]` 且**绝不**调用 `CofService`;
    /// 无凭证 → `[]`;列卡抛错 → 吞掉并返回 `[]`(降级为仅新卡)。本方法**绝不**抛出。
    ///
    /// - Returns: 已保存卡列表,或在不可用/失败时为空。
    func listSavedCards() async -> [SavedCard] {
        guard let session, session.cofEnabled else {
            return []
        }
        guard let secret = await credentials.current() else {
            return []
        }
        do {
            return try await cofService.listPaymentMethods(
                customerAccessSecret: secret,
                sessionId: session.id
            )
        } catch {
            // 降级:不抛出,退回仅新卡。
            return []
        }
    }

    // MARK: - 三条确认路径

    /// 新卡支付(可选存卡)。
    ///
    /// 本地加密卡数据(明文仅此刻在内存,随作用域释放),以 `cardEncryptedData` 提交。
    func confirmNewCard(_ input: CardInput, save: Bool, consent: Consent?) async -> CheckoutOutcome {
        guard let session else {
            return .failed(txnId: nil, error: CheckoutErrors.sessionExpired())
        }
        guard let attemptId = beginAttempt() else {
            return .failed(txnId: nil, error: CheckoutErrors.alreadyPresenting())
        }
        defer { endAttempt() }

        // 加密(§7.2):缺公钥或加密失败 → 不提交,直接失败(终态,清凭证)。
        guard let rsaKey = session.rsaPublicKey else {
            await terminalCleanup()
            return .failed(txnId: nil, error: CheckoutErrors.encryptionFailed())
        }
        let encrypted: String
        do {
            encrypted = try CardEncryptor.encrypt(input, rsaPublicKeyBase64: rsaKey)
        } catch {
            await terminalCleanup()
            return .failed(txnId: nil, error: CheckoutErrors.encryptionFailed())
        }

        let request = SubmitRequest(
            sessionId: session.id,
            paymentMethod: "CARD",
            attemptId: attemptId,
            cardEncryptedData: encrypted,
            savePaymentMethod: save ? true : nil,
            consent: consent
        )
        return await submitAndResolve(request)
    }

    /// COF 已保存卡快捷支付(零验证)。仅携带 `paymentMethodId`,不带卡数据。
    func confirmSavedCard(paymentMethodId: String) async -> CheckoutOutcome {
        guard let session else {
            return .failed(txnId: nil, error: CheckoutErrors.sessionExpired())
        }
        guard let attemptId = beginAttempt() else {
            return .failed(txnId: nil, error: CheckoutErrors.alreadyPresenting())
        }
        defer { endAttempt() }

        let request = SubmitRequest(
            sessionId: session.id,
            paymentMethod: "CARD",
            attemptId: attemptId,
            paymentMethodId: paymentMethodId
        )
        return await submitAndResolve(request)
    }

    /// Apple Pay 钱包支付。仅携带 `walletToken`。
    func confirmWallet(token: Data) async -> CheckoutOutcome {
        guard let session else {
            return .failed(txnId: nil, error: CheckoutErrors.sessionExpired())
        }
        guard let attemptId = beginAttempt() else {
            return .failed(txnId: nil, error: CheckoutErrors.alreadyPresenting())
        }
        defer { endAttempt() }

        let request = SubmitRequest(
            sessionId: session.id,
            paymentMethod: "APPLE_PAY",
            attemptId: attemptId,
            walletToken: token
        )
        return await submitAndResolve(request)
    }

    // MARK: - 查询 / 关闭

    /// 独立于 UI 的结果查询(崩溃/被杀恢复,§4.3)。
    func retrievePayment(sessionId: String) async throws -> PaymentSnapshot {
        try await paymentService.getResult(sessionId: sessionId)
    }

    /// 结束 UI 会话:清活跃状态与凭证。**不**取消服务端交易(§规格)。
    func dismiss() async {
        activeAttempt = nil
        session = nil
        await credentials.clear()
    }

    // MARK: - 私有:单活跃守卫

    /// 尝试占用单活跃锁并生成一次 attemptId。
    ///
    /// - Returns: 占用成功返回新 `attemptId`;已被占用返回 nil(调用方映射为 alreadyPresenting)。
    ///
    /// - Note: 本方法为同步、无 `await`,在 actor 隔离域内原子地完成「检查 + 占用 + 生成键」,
    ///   这正是单活跃不变量的载体:两次并发 confirm 会被 actor 串行化,后者必见 `activeAttempt != nil`。
    private func beginAttempt() -> UUID? {
        guard activeAttempt == nil else { return nil }
        let id = UUID()
        activeAttempt = id
        return id
    }

    /// 释放单活跃锁(一次 confirm 结束时)。
    private func endAttempt() {
        activeAttempt = nil
    }

    // MARK: - 私有:提交 + 结果解析

    /// 提交并把结果解析为 `CheckoutOutcome`。
    ///
    /// 「提交失败先查询」(§4.2):`submit` 抛错时**不**重发,改调 `getResult` 一次;
    /// `getResult` 也失败 → `.unknown`。成功响应按快照状态映射(见 `mapSnapshot`)。
    /// 每次 confirm 仅调用一次本方法、仅产出一个 outcome(结果去重:映射只算一次)。
    private func submitAndResolve(_ request: SubmitRequest) async -> CheckoutOutcome {
        let snapshot: PaymentSnapshot
        do {
            snapshot = try await paymentService.submit(request)
        } catch {
            // 失败先查询,绝不盲目重发同一 attemptId。
            do {
                snapshot = try await paymentService.getResult(sessionId: request.sessionId)
            } catch {
                await terminalCleanupIfTerminal(.unknown(sessionId: request.sessionId))
                return .unknown(sessionId: request.sessionId)
            }
        }
        return await mapSnapshot(snapshot)
    }

    /// 快照 → 结果映射(§4.5 / §7.4)。
    ///
    /// - `S` → `.succeeded`(终态,清凭证)
    /// - `F` → `.failed`(终态,清凭证)
    /// - `I` → 非终态:驱动 `ResultPoller` 轮询至终态或上限(§4.4),再映射轮询结果:
    ///   终态 → succeeded/failed(清凭证);达上限仍非终态 → `.unknown`(清凭证)
    /// - `R` → 委派 `ActionHandling`:`.pending` → `.pending`,`.failed(err)` → `.failed`
    private func mapSnapshot(_ snapshot: PaymentSnapshot) async -> CheckoutOutcome {
        switch snapshot.status {
        case .succeeded:
            let txnId = snapshot.txnId ?? ""
            await terminalCleanup()
            return .succeeded(txnId: txnId)

        case .failed:
            await terminalCleanup()
            return .failed(txnId: snapshot.txnId, error: CheckoutErrors.paymentFailed())

        case .initial:
            // 非终态:轮询至终态或上限(Task 7)。轮询用注入/默认 ResultPoller。
            let polled = await poller.pollUntilTerminal(sessionId: snapshot.sessionId)
            switch polled.status {
            case .succeeded:
                await terminalCleanup()
                return .succeeded(txnId: polled.txnId ?? "")
            case .failed:
                await terminalCleanup()
                return .failed(txnId: polled.txnId, error: CheckoutErrors.paymentFailed())
            case .initial, .requiresAction:
                // 达上限仍非终态 → unknown(非失败,§4.3);清 UI 侧凭证。
                await terminalCleanup()
                return .unknown(sessionId: snapshot.sessionId)
            }

        case .requiresAction:
            // 取动作(seam):服务实现若提供 action 则用之,否则按 .unknown 兜底(→ 不支持)。
            let action = (paymentService as? PaymentActionProviding)?
                .actionForLatestRequiresAction() ?? .unknown
            let result = await actionHandler.handle(action, sessionId: snapshot.sessionId)
            switch result {
            case .pending:
                // requiresAction 本身非终态:等待回跳/轮询确认,不清凭证。
                return .pending(txnId: snapshot.txnId)
            case .failed(let error):
                await terminalCleanup()
                return .failed(txnId: snapshot.txnId, error: error)
            }
        }
    }

    /// 终态清理:清凭证(§4.2 终态即清)。活跃锁由各 confirm 的 `defer { endAttempt() }` 释放。
    private func terminalCleanup() async {
        await credentials.clear()
    }

    /// 若给定 outcome 为终态则清理。`unknown` 不是交易终态,但按规格在网络中断时也应清理 UI 侧凭证:
    /// 这里对 `unknown` 同样清凭证(会话已不可继续在本 UI 推进)。
    private func terminalCleanupIfTerminal(_ outcome: CheckoutOutcome) async {
        switch outcome {
        case .succeeded, .failed, .unknown:
            await credentials.clear()
        case .pending, .canceled:
            break
        }
    }
}
