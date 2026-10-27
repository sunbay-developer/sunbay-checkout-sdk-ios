import Foundation
import XCTest

@testable import SunbayCheckout

/// `ResultPoller` 的轮询 / 退避 / 上限测试(Task 7 Step 1)。
///
/// 覆盖 product-spec §4.4 轮询默认参数:初始 1s → 退避至最大 5s;总上限 ~90s;
/// 达上限且仍非终态 → 返回最新非终态快照(控制器据此映射 `.unknown`)。
///
/// 所有等待通过注入的 `sleep` 闭包完成,**不**真正休眠:测试既保持确定、快速,
/// 又能捕获请求的退避区间(秒)。
final class ResultPollerTests: XCTestCase {
    // MARK: - 捕获注入休眠区间的记录器

    /// 线程安全地记录每次请求的 `sleep` 时长(秒)。poller 为 actor,会在隔离域内调用。
    private final class SleepRecorder: @unchecked Sendable {
        private let lock = NSLock()
        private var _intervals: [TimeInterval] = []

        var intervals: [TimeInterval] {
            lock.lock(); defer { lock.unlock() }
            return _intervals
        }

        /// 作为注入 `sleep` 使用:记录时长但不真正等待。
        func sleep(_ seconds: TimeInterval) async throws {
            lock.lock()
            _intervals.append(seconds)
            lock.unlock()
        }
    }

    private func snapshot(_ status: TxnStatus, txnId: String? = nil) -> PaymentSnapshot {
        PaymentSnapshot(sessionId: "sess_1", status: status, txnId: txnId)
    }

    // 短上限 + 短初始/最大,保证 always-I 用例在少量步进内即达上限。
    private func fastConfig() -> PollConfig {
        PollConfig(initial: 0.001, max: 0.008, overallLimit: 0.03)
    }

    // MARK: - 1. I, I, S → 解析为成功终态

    func test_pollUntilTerminal_resolvesSucceeded_afterTwoPendingTicks() async {
        let payment = MockPaymentService()
        payment.stubGetResult([
            snapshot(.initial),
            snapshot(.initial),
            snapshot(.succeeded, txnId: "txn_ok"),
        ])
        let recorder = SleepRecorder()
        let poller = ResultPoller(
            service: payment,
            config: PollConfig.default,
            sleep: recorder.sleep
        )

        let result = await poller.pollUntilTerminal(sessionId: "sess_1")

        XCTAssertEqual(result.status, .succeeded)
        XCTAssertEqual(result.txnId, "txn_ok")
        XCTAssertEqual(payment.getResultCallCount, 3, "应查询到第三次拿到终态")
        // 两次非终态之后各退避一次(终态返回前不再等待)。
        XCTAssertEqual(recorder.intervals.count, 2, "两次非终态 → 两次退避")
    }

    // MARK: - 2. 始终 I,达上限 → 返回最后的 I 快照(控制器 → unknown)

    func test_pollUntilTerminal_alwaysPending_returnsLastSnapshotAtLimit() async {
        let payment = MockPaymentService()
        payment.stubGetResult([snapshot(.initial, txnId: "txn_pending")])
        let recorder = SleepRecorder()
        let poller = ResultPoller(
            service: payment,
            config: fastConfig(),
            sleep: recorder.sleep
        )

        let result = await poller.pollUntilTerminal(sessionId: "sess_1")

        XCTAssertEqual(result.status, .initial, "达上限仍非终态应返回最新非终态快照")
        XCTAssertEqual(result.txnId, "txn_pending")
        XCTAssertGreaterThan(payment.getResultCallCount, 1, "达上限前应多次查询")
    }

    // MARK: - 3. 退避调度:初始 → 翻倍 → 封顶 max

    func test_backoffSchedule_doublesThenCapsAtMax() async {
        let payment = MockPaymentService()
        // 始终非终态,强制走满退避阶梯直到上限。
        payment.stubGetResult([snapshot(.initial)])
        let recorder = SleepRecorder()
        // initial=1s 翻倍:1,2,4,8(>5 封顶到 5),5,5… 上限 100s 足够观察封顶。
        let config = PollConfig(initial: 1, max: 5, overallLimit: 100)
        let poller = ResultPoller(service: payment, config: config, sleep: recorder.sleep)

        _ = await poller.pollUntilTerminal(sessionId: "sess_1")

        let intervals = recorder.intervals
        XCTAssertGreaterThanOrEqual(intervals.count, 6, "应观察到封顶后的多个 5s 步进")
        XCTAssertEqual(intervals[0], 1, accuracy: 0.0001, "第 1 次退避 = 初始 1s")
        XCTAssertEqual(intervals[1], 2, accuracy: 0.0001, "第 2 次 = 翻倍 2s")
        XCTAssertEqual(intervals[2], 4, accuracy: 0.0001, "第 3 次 = 翻倍 4s")
        XCTAssertEqual(intervals[3], 5, accuracy: 0.0001, "第 4 次封顶 5s(8 → 封顶)")
        XCTAssertEqual(intervals[4], 5, accuracy: 0.0001, "此后保持 5s")
        XCTAssertEqual(intervals[5], 5, accuracy: 0.0001, "此后保持 5s")
    }

    // MARK: - getResult 抛错不应中止轮询(瞬时错误按非终态步进处理)

    func test_getResultThrows_keepsPollingUntilLimit_thenReturnsLastSnapshot() async {
        let payment = MockPaymentService()
        // getResult 一直抛错:应继续轮询到上限,从未拿到快照 → 兜底为 .initial(非终态),控制器 → unknown。
        payment.stubGetResult([snapshot(.initial, txnId: "txn_x")])
        payment.stubGetResultError(URLError(.timedOut))
        let recorder = SleepRecorder()
        let poller = ResultPoller(service: payment, config: fastConfig(), sleep: recorder.sleep)

        let result = await poller.pollUntilTerminal(sessionId: "sess_1")

        XCTAssertEqual(result.status, .initial, "瞬时错误不得中止轮询;达上限兜底为非终态")
        XCTAssertGreaterThan(payment.getResultCallCount, 1, "抛错后仍应继续轮询")
    }
}
