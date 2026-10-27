import Foundation

/// 轮询参数(product-spec §4.4,可配置,后端 ready 后微调)。
///
/// 时长单位用 `TimeInterval`(秒,`Double`)而非 `Duration`:`Duration` 需 iOS 16+,
/// 而本 SDK 最低目标为 iOS 15(见 implementation-plan Global Constraints),故统一用秒。
///
/// - `initial`:首个退避间隔(秒)。
/// - `max`:退避封顶(秒);指数翻倍不超过此值。
/// - `overallLimit`:累计耗时上限(秒);达上限且仍非终态 → 返回最新非终态快照
///   (控制器据此映射 `.unknown`,§4.3「达上限 → unknown」)。
///
/// 默认 `initial = 1s`、`max = 5s`、`overallLimit = 90s`(§4.4:初始 1s → 退避至最大 5s;总上限 ~90s)。
struct PollConfig: Sendable, Equatable {
    /// 首个退避间隔(秒)。
    var initial: TimeInterval
    /// 退避封顶(秒)。
    var max: TimeInterval
    /// 累计耗时上限(秒)。
    var overallLimit: TimeInterval

    /// 创建轮询参数。
    ///
    /// - Parameters:
    ///   - initial: 首个退避间隔(秒)。
    ///   - max: 退避封顶(秒)。
    ///   - overallLimit: 累计耗时上限(秒)。
    init(initial: TimeInterval, max: TimeInterval, overallLimit: TimeInterval) {
        self.initial = initial
        self.max = max
        self.overallLimit = overallLimit
    }

    /// §4.4 默认参数:初始 1s → 封顶 5s;总上限 90s。
    static let `default` = PollConfig(initial: 1, max: 5, overallLimit: 90)
}

/// 结果轮询器(§4.4 / §4.3)。
///
/// 反复调用 `service.getResult(sessionId:)`:
/// - 命中终态(`.succeeded` / `.failed`)→ **立即**返回该快照;
/// - 非终态(`.initial` / `.requiresAction`)→ 以**指数退避**(自 `initial` 起翻倍,封顶 `max`)等待,
///   直到累计耗时达到 `overallLimit`,然后返回**最新非终态快照**(控制器据此 → `.unknown`)。
///
/// ## 确定性测试缝(seam)
/// 等待通过注入的 `sleep` 闭包完成(入参为秒)。生产默认用 `Task.sleep(nanoseconds:)`;测试注入
/// 「零等待 + 记录时长」的替身,使测试快速、确定,并可断言请求的退避阶梯。
///
/// ## `getResult` 抛错的处理(已决策并记录)
/// 瞬时 `getResult` 错误**不**中止轮询:按一次非终态步进处理(退避后重试),直到达上限;
/// 达上限时返回**目前为止观测到的最新非终态快照**。若从未成功拿到任何快照(例如 getResult 一直抛错),
/// 则兜底返回一个 `.initial` 快照(非终态),由控制器映射为 `.unknown`——**绝不崩溃**,也**绝不**把瞬时
/// 网络抖动当作支付失败。
///
/// `actor` 隔离;不 import 任何 UIKit/PassKit(Core UI 无关)。
actor ResultPoller {
    private let service: any PaymentService
    private let config: PollConfig
    private let sleep: @Sendable (TimeInterval) async throws -> Void

    /// 创建结果轮询器。
    ///
    /// - Parameters:
    ///   - service: 支付后端能力(用于 `getResult`)。
    ///   - config: 轮询参数,默认 `.default`。
    ///   - sleep: 等待实现(注入缝,入参为秒),默认 `Task.sleep(nanoseconds:)`。
    init(
        service: any PaymentService,
        config: PollConfig = .default,
        sleep: @escaping @Sendable (TimeInterval) async throws -> Void = { seconds in
            try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
        }
    ) {
        self.service = service
        self.config = config
        self.sleep = sleep
    }

    /// 轮询至终态或上限。
    ///
    /// - Parameter sessionId: 会话标识。
    /// - Returns: 终态快照(`.succeeded` / `.failed`),或达上限时的最新非终态快照。
    func pollUntilTerminal(sessionId: String) async -> PaymentSnapshot {
        // 目前为止观测到的最新非终态快照;从未成功查询时兜底为 .initial。
        var latestNonTerminal = PaymentSnapshot(sessionId: sessionId, status: .initial, txnId: nil)
        var elapsed: TimeInterval = 0
        var backoff = config.initial

        while true {
            // 1) 查询一次结果;瞬时错误不中止,按非终态步进处理。
            if let snapshot = try? await service.getResult(sessionId: sessionId) {
                if isTerminal(snapshot.status) {
                    return snapshot
                }
                latestNonTerminal = snapshot
            }

            // 2) 若再退避一次就会越过上限,则停止并返回最新非终态快照。
            if elapsed + backoff > config.overallLimit {
                return latestNonTerminal
            }

            // 3) 退避等待(注入 sleep);等待本身出错不致命,按步进继续。
            try? await sleep(backoff)
            elapsed += backoff

            // 4) 指数退避:翻倍并封顶 max。
            backoff = Swift.min(backoff * 2, config.max)
        }
    }

    /// 终态判定:`S` / `F` 为终态;`I` / `R` 非终态。
    private func isTerminal(_ status: TxnStatus) -> Bool {
        switch status {
        case .succeeded, .failed:
            return true
        case .initial, .requiresAction:
            return false
        }
    }
}
