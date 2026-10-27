import Foundation
import XCTest

@testable import SunbayCheckout

/// Polling / backoff / limit tests for `ResultPoller` (Task 7 Step 1).
///
/// Covers the default polling parameters in product-spec §4.4: initial 1s → back off to max 5s; overall
/// limit ~90s; on reaching the limit while still non-terminal → return the latest non-terminal snapshot
/// (the controller maps this to `.unknown`).
///
/// All waiting goes through the injected `sleep` closure and does **not** actually sleep: the tests stay
/// deterministic and fast while still capturing the requested backoff intervals (seconds).
final class ResultPollerTests: XCTestCase {
    // MARK: - Recorder capturing the injected sleep intervals

    /// Thread-safely records the `sleep` duration (seconds) of each request. The poller is an actor and calls it within its isolation domain.
    private final class SleepRecorder: @unchecked Sendable {
        private let lock = NSLock()
        private var _intervals: [TimeInterval] = []

        var intervals: [TimeInterval] {
            lock.lock(); defer { lock.unlock() }
            return _intervals
        }

        /// Used as the injected `sleep`: records the duration without actually waiting.
        func sleep(_ seconds: TimeInterval) async throws {
            lock.lock()
            _intervals.append(seconds)
            lock.unlock()
        }
    }

    private func snapshot(_ status: TxnStatus, txnId: String? = nil) -> PaymentSnapshot {
        PaymentSnapshot(sessionId: "sess_1", status: status, txnId: txnId)
    }

    // Short limit + short initial/max, ensuring the always-I case reaches the limit within a few steps.
    private func fastConfig() -> PollConfig {
        PollConfig(initial: 0.001, max: 0.008, overallLimit: 0.03)
    }

    // MARK: - 1. I, I, S → resolves to the success terminal state

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
        XCTAssertEqual(payment.getResultCallCount, 3, "should reach the terminal state on the third query")
        // After each of the two non-terminal ticks there is one backoff (no wait before returning the terminal state).
        XCTAssertEqual(recorder.intervals.count, 2, "two non-terminal ticks → two backoffs")
    }

    // MARK: - 2. always I, reach the limit → return the last I snapshot (controller → unknown)

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

        XCTAssertEqual(result.status, .initial, "reaching the limit while still non-terminal should return the latest non-terminal snapshot")
        XCTAssertEqual(result.txnId, "txn_pending")
        XCTAssertGreaterThan(payment.getResultCallCount, 1, "should query multiple times before reaching the limit")
    }

    // MARK: - 3. backoff schedule: initial → double → cap at max

    func test_backoffSchedule_doublesThenCapsAtMax() async {
        let payment = MockPaymentService()
        // Always non-terminal, forcing the full backoff ladder until the limit.
        payment.stubGetResult([snapshot(.initial)])
        let recorder = SleepRecorder()
        // initial=1s doubling: 1,2,4,8 (>5 caps to 5),5,5… an overall limit of 100s is enough to observe the cap.
        let config = PollConfig(initial: 1, max: 5, overallLimit: 100)
        let poller = ResultPoller(service: payment, config: config, sleep: recorder.sleep)

        _ = await poller.pollUntilTerminal(sessionId: "sess_1")

        let intervals = recorder.intervals
        XCTAssertGreaterThanOrEqual(intervals.count, 6, "should observe multiple 5s steps after the cap")
        XCTAssertEqual(intervals[0], 1, accuracy: 0.0001, "backoff #1 = initial 1s")
        XCTAssertEqual(intervals[1], 2, accuracy: 0.0001, "#2 = doubled 2s")
        XCTAssertEqual(intervals[2], 4, accuracy: 0.0001, "#3 = doubled 4s")
        XCTAssertEqual(intervals[3], 5, accuracy: 0.0001, "#4 capped at 5s (8 → capped)")
        XCTAssertEqual(intervals[4], 5, accuracy: 0.0001, "stays 5s afterward")
        XCTAssertEqual(intervals[5], 5, accuracy: 0.0001, "stays 5s afterward")
    }

    // MARK: - getResult throwing should not abort polling (transient errors are treated as a non-terminal tick)

    func test_getResultThrows_keepsPollingUntilLimit_thenReturnsLastSnapshot() async {
        let payment = MockPaymentService()
        // getResult keeps throwing: should keep polling until the limit, never obtaining a snapshot → falls back to .initial (non-terminal), controller → unknown.
        payment.stubGetResult([snapshot(.initial, txnId: "txn_x")])
        payment.stubGetResultError(URLError(.timedOut))
        let recorder = SleepRecorder()
        let poller = ResultPoller(service: payment, config: fastConfig(), sleep: recorder.sleep)

        let result = await poller.pollUntilTerminal(sessionId: "sess_1")

        XCTAssertEqual(result.status, .initial, "a transient error must not abort polling; on reaching the limit, fall back to non-terminal")
        XCTAssertGreaterThan(payment.getResultCallCount, 1, "should keep polling after a throw")
    }
}
