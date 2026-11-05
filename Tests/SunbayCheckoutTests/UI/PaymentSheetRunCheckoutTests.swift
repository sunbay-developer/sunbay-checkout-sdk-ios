#if canImport(UIKit)
    import UIKit
    import XCTest

    @testable import SunbayCheckout

    /// Retry-loop coverage for the rewired `PaymentSheet` (Task 9) plus the container's state bridge.
    ///
    /// ## Where the retry lives
    /// `runCheckout(seam:)` stays **single-shot** (one seam call → one confirm → one outcome), to
    /// preserve the existing `PaymentSheetTests`. The retry loop is implemented in the
    /// present/container layer: on a non-terminal outcome (`.failed` / `.pending` / `.unknown`) the
    /// content VC stays open and re-editable, and the next user confirm drives **another**
    /// `runCheckout` attempt. The present layer therefore loops `runCheckout` — one call per confirm.
    ///
    /// These tests exercise that exact mechanism at the `runCheckout` seam the present layer loops
    /// over: calling `runCheckout` twice (a first confirm whose submit fails, a second whose submit
    /// succeeds) models "failed round → user taps again → second confirm succeeds". This runs
    /// headlessly (no real UIKit presentation), identical to how `PaymentSheetTests` drives the seam.
    ///
    /// UIKit is iOS-only; on the macOS host this whole file is excluded by `#if canImport(UIKit)`. The
    /// real RED/GREEN requires building against the iOS Simulator SDK (see the task report).
    final class PaymentSheetRunCheckoutTests: XCTestCase {
        // MARK: - Assembly

        private func makeSession(id: String, cofEnabled: Bool) -> CheckoutSession {
            CheckoutSession(
                id: id,
                amount: Amount(minorUnits: 999, currencyCode: "USD"),
                merchantName: "Acme",
                methods: [.card, .savedCard],
                expiresAt: Date().addingTimeInterval(600),
                rsaPublicKey: nil,
                cofEnabled: cofEnabled
            )
        }

        /// Assembles a real `CheckoutController` with a mock backend; the submit sequence is scripted
        /// so the first confirm fails and the second succeeds.
        private func makeController(
            session: CheckoutSession,
            cards: [SavedCard],
            submit snapshots: [PaymentSnapshot]
        ) -> (CheckoutController, MockPaymentService, MockCofService) {
            let payment = MockPaymentService()
            payment.stubSession(session)
            payment.stubSubmit(snapshots)
            let cof = MockCofService()
            cof.stubCards(cards)
            let controller = CheckoutController(
                paymentService: payment,
                cofService: cof,
                credentials: CredentialStore(),
                actionHandler: StubActionHandler(result: .pending)
            )
            return (controller, payment, cof)
        }

        // MARK: - Retry loop

        /// A failed first confirm followed by a successful second confirm: two `runCheckout` attempts
        /// (what the present layer loops over) map to two submits, and the second returns success.
        func test_retryAfterFailedConfirmsAgain() async {
            let sessionId = "sess_retry_1"
            let session = makeSession(id: sessionId, cofEnabled: true)
            let card = SavedCard(id: "pm_1", brand: "visa", last4: "4242", expMonth: 12, expYear: 2030)
            let (controller, payment, _) = makeController(
                session: session,
                cards: [card],
                submit: [
                    PaymentSnapshot(sessionId: sessionId, status: .failed, txnId: "t1"),
                    PaymentSnapshot(sessionId: sessionId, status: .succeeded, txnId: "t2"),
                ]
            )

            let sheet = PaymentSheet(
                controller: controller,
                sessionId: sessionId,
                customerAccessSecret: "secret_abc"
            )

            // Round 1: confirm the saved card → submit scripted to fail.
            let first = await sheet.runCheckout { _ in .confirmSavedCard(paymentMethodId: "pm_1") }
            guard case .failed = first else {
                return XCTFail("expected .failed on the first attempt, got \(first)")
            }

            // Round 2 (the retry the present layer drives after the sheet stayed open): confirm again
            // → submit scripted to succeed.
            let second = await sheet.runCheckout { _ in .confirmSavedCard(paymentMethodId: "pm_1") }

            XCTAssertEqual(second, .succeeded(txnId: "t2"))
            // Each confirm reached the backend exactly once: no blind resubmit, one submit per attempt.
            XCTAssertEqual(payment.submitCallCount, 2)
        }

        /// The single-active guard holds across rounds: a confirm that is NOT retried submits exactly
        /// once, and a cancel never submits. Guards against the loop re-submitting on its own.
        func test_singleActiveGuardStillHoldsAcrossRounds() async {
            let sessionId = "sess_retry_2"
            let session = makeSession(id: sessionId, cofEnabled: true)
            let card = SavedCard(id: "pm_1", brand: "visa", last4: "4242", expMonth: 12, expYear: 2030)
            let (controller, payment, _) = makeController(
                session: session,
                cards: [card],
                submit: [PaymentSnapshot(sessionId: sessionId, status: .succeeded, txnId: "ok")]
            )

            let sheet = PaymentSheet(
                controller: controller,
                sessionId: sessionId,
                customerAccessSecret: "secret_abc"
            )

            // One successful confirm → terminal; the present layer would stop looping here.
            let outcome = await sheet.runCheckout { _ in .confirmSavedCard(paymentMethodId: "pm_1") }
            XCTAssertEqual(outcome, .succeeded(txnId: "ok"))
            XCTAssertEqual(payment.submitCallCount, 1, "exactly one submit for one confirm")

            // A subsequent cancel round (user dismisses) must not submit again.
            let canceled = await sheet.runCheckout { _ in .cancel }
            guard case .canceled = canceled else {
                return XCTFail("expected .canceled, got \(canceled)")
            }
            XCTAssertEqual(payment.submitCallCount, 1, "a cancel round must not submit")
        }

        // MARK: - Dismissal outcome correction

        /// `present()`'s dismissal-outcome rule: `.pending`/`.unknown` as the last known outcome is
        /// reported as-is on close (NOT `.canceled`), since a payment may still be in flight; `.failed`
        /// (and no attempt at all) stays `.canceled` on close.
        func test_outcomeOnClose_pendingOrUnknown_reportedAsIs_otherwiseCanceled() {
            XCTAssertEqual(
                PaymentSheet.outcomeOnClose(lastKnown: .pending(txnId: "t")), .pending(txnId: "t"),
                "an unsettled pending attempt must be surfaced, not swallowed into .canceled")
            XCTAssertEqual(
                PaymentSheet.outcomeOnClose(lastKnown: .unknown(sessionId: "s1")), .unknown(sessionId: "s1"),
                "an unsettled unknown attempt must be surfaced, not swallowed into .canceled")
            XCTAssertEqual(
                PaymentSheet.outcomeOnClose(lastKnown: .failed(txnId: nil, error: CheckoutErrors.paymentFailed())),
                .canceled, "a confirmed failure on close is a genuine cancel")
            XCTAssertEqual(
                PaymentSheet.outcomeOnClose(lastKnown: .canceled), .canceled,
                "no attempt at all (the user never confirmed) stays a genuine cancel")
        }

        // MARK: - present() end to end

        /// What a presented real sheet exposes to a test.
        private struct Presented {
            let task: Task<CheckoutOutcome, Never>
            let container: PaymentSheetContainerViewController
            let content: CheckoutContentViewController
            let window: UIWindow
            let payment: MockPaymentService
            /// Resolves `present()`'s value, or `nil` if it has not returned within `seconds`.
            @MainActor
            func outcome(within seconds: TimeInterval = 10) async -> CheckoutOutcome? {
                let box = OutcomeBox()
                let t = task
                Task { box.set(await t.value) }
                let deadline = Date().addingTimeInterval(seconds)
                while box.value == nil, Date() < deadline {
                    try? await Task.sleep(nanoseconds: 20_000_000)
                }
                return box.value
            }
            func tearDown() {
                window.isHidden = true
                window.rootViewController = nil
            }
        }

        private final class LockedFlag: @unchecked Sendable {
            private let lock = NSLock()
            private var _set = false
            var isSet: Bool { lock.lock(); defer { lock.unlock() }; return _set }
            func set() { lock.lock(); _set = true; lock.unlock() }
        }

        private final class OutcomeBox: @unchecked Sendable {
            private let lock = NSLock()
            private var _value: CheckoutOutcome?
            var value: CheckoutOutcome? { lock.lock(); defer { lock.unlock() }; return _value }
            func set(_ v: CheckoutOutcome) { lock.lock(); _value = v; lock.unlock() }
        }

        /// A deterministic, wall-clock-free gate for ordering-sensitive races. Code under test calls
        /// `await wait()` (which suspends until `release()`), and the test can `await untilEntered()` to
        /// observe that the gate has actually been reached. This replaces time-based `stubLoadDelay`
        /// windows in races where "the code is parked HERE" must be guaranteed, not merely likely.
        private final class MockGate: @unchecked Sendable {
            private let lock = NSLock()
            private var released = false
            private var waiters: [CheckedContinuation<Void, Never>] = []
            private var enteredWaiters: [CheckedContinuation<Void, Never>] = []
            private var entered = false

            /// Called from code under test: suspends until `release()`, then returns. After release it
            /// returns immediately. Also signals any `untilEntered()` awaiter that the gate was reached.
            func wait() async {
                await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
                    lock.lock()
                    entered = true
                    let toEnter = enteredWaiters
                    enteredWaiters.removeAll()
                    if released {
                        lock.unlock()
                        for e in toEnter { e.resume() }
                        c.resume()
                        return
                    }
                    waiters.append(c)
                    lock.unlock()
                    for e in toEnter { e.resume() }
                }
            }

            /// Called from the test: suspends until the gate has been entered by code under test.
            func untilEntered() async {
                await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
                    lock.lock()
                    if entered {
                        lock.unlock()
                        c.resume()
                        return
                    }
                    enteredWaiters.append(c)
                    lock.unlock()
                }
            }

            /// Called from the test: releases all current and future waiters.
            func release() {
                lock.lock()
                released = true
                let toResume = waiters
                waiters.removeAll()
                lock.unlock()
                for w in toResume { w.resume() }
            }
        }

        /// Zero-wait poller with a one-query bound (`overallLimit: 0` → exactly one `getResult` per poll),
        /// so call counts are deterministic and nothing sleeps for real.
        private func makeZeroWaitPoller(_ payment: MockPaymentService) -> ResultPoller {
            ResultPoller(
                service: payment, config: PollConfig(initial: 0.001, max: 0.001, overallLimit: 0),
                sleep: { _ in })
        }

        /// Presents the real sheet over a test window; returns what's needed to drive it. The localizer
        /// is the identity so notices can be asserted by key.
        @MainActor
        private func presentSheet(
            submit: [PaymentSnapshot], getResult: [PaymentSnapshot],
            poller: ((MockPaymentService) -> ResultPoller)? = nil,
            configure: ((MockPaymentService) -> Void)? = nil
        ) async throws -> Presented {
            let sessionId = "sess_present"
            let payment = MockPaymentService()
            payment.stubSession(makeSession(id: sessionId, cofEnabled: true))
            if !submit.isEmpty { payment.stubSubmit(submit) }
            if !getResult.isEmpty { payment.stubGetResult(getResult) }
            configure?(payment)
            let cof = MockCofService()
            cof.stubCards([SavedCard(id: "pm_1", brand: "visa", last4: "4242", expMonth: 12, expYear: 2030)])
            let controller = CheckoutController(
                paymentService: payment,
                cofService: cof,
                credentials: CredentialStore(),
                actionHandler: StubActionHandler(result: .pending),
                poller: poller?(payment) ?? makeZeroWaitPoller(payment)
            )
            let sheet = PaymentSheet(
                controller: controller, sessionId: sessionId, customerAccessSecret: "secret_abc",
                localize: { $0 })

            let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 844))
            let root = UIViewController()
            window.rootViewController = root
            window.makeKeyAndVisible()

            let task = Task { @MainActor in await sheet.present(from: root) }

            let deadline = Date().addingTimeInterval(5)
            while !(root.presentedViewController is PaymentSheetContainerViewController), Date() < deadline {
                try await Task.sleep(nanoseconds: 20_000_000)
            }
            let container = try XCTUnwrap(root.presentedViewController as? PaymentSheetContainerViewController)
            container.loadViewIfNeeded()
            let content = try XCTUnwrap(container.children.first as? CheckoutContentViewController)
            content.loadViewIfNeeded()
            return Presented(task: task, container: container, content: content, window: window, payment: payment)
        }

        /// Polls until `condition` holds (main-actor), or fails after `seconds`.
        @MainActor
        private func waitUntil(
            _ what: String, seconds: TimeInterval = 8, _ condition: () -> Bool
        ) async throws {
            let deadline = Date().addingTimeInterval(seconds)
            while !condition(), Date() < deadline {
                try await Task.sleep(nanoseconds: 20_000_000)
            }
            XCTAssertTrue(condition(), "timed out waiting for: \(what)")
        }

        private func isFailed(_ state: CheckoutViewState) -> Bool {
            if case .failed = state { return true }
            return false
        }

        private func isUnknown(_ outcome: CheckoutOutcome?) -> Bool {
            if case .unknown = outcome { return true }
            return false
        }

        private let initialSnap = PaymentSnapshot(sessionId: "sess_present", status: .initial, txnId: nil)

        /// Selects the saved card and taps Pay (the first, unsettled attempt).
        @MainActor
        private func payWithSavedCard(_ p: Presented) {
            p.content.tapSavedCardRowForTest("pm_1")
            p.content.simulateTapPay()
        }

        /// A `.unknown` attempt followed by the user closing the sheet: `present()` returns `.unknown`
        /// (so the host calls `retrievePayment()`), NOT `.canceled`.
        @MainActor
        func test_present_closeAfterUnknown_returnsUnknown_notCanceled() async throws {
            let p = try await presentSheet(submit: [initialSnap], getResult: [initialSnap])
            defer { p.tearDown() }

            payWithSavedCard(p)
            try await waitUntil("reconciling") { p.content.currentViewState == .reconciling }
            XCTAssertTrue(p.container.requestCancel(), "✕ / backdrop must still work while reconciling")

            let outcome = await p.outcome()
            XCTAssertEqual(outcome, .unknown(sessionId: "sess_present"))
        }

        /// Genuine cancel: the user closes before ever submitting anything → still `.canceled`.
        @MainActor
        func test_present_closeBeforeAnySubmit_returnsCanceled() async throws {
            let p = try await presentSheet(submit: [], getResult: [])
            defer { p.tearDown() }

            XCTAssertTrue(p.container.requestCancel())

            let outcome = await p.outcome()
            XCTAssertEqual(outcome, .canceled)
        }

        // MARK: - F1: automatic in-sheet reconciliation

        /// `.unknown` auto-reconciles in the sheet: a terminal success follows the normal success path
        /// (auto-close) without the user closing anything, and `present()` returns `.succeeded`. Exactly
        /// two queries happened (the submit's own bounded poll + the reconcile) and one submit.
        @MainActor
        func test_autoReconcile_resolvesSucceeded_autoCloses() async throws {
            let succeeded = PaymentSnapshot(sessionId: "sess_present", status: .succeeded, txnId: "txn_r")
            let p = try await presentSheet(submit: [initialSnap], getResult: [initialSnap, succeeded])
            defer { p.tearDown() }

            payWithSavedCard(p)

            let outcome = await p.outcome()
            XCTAssertEqual(outcome, .succeeded(txnId: "txn_r"))
            XCTAssertEqual(p.payment.submitCallCount, 1, "reconcile must never submit")
            XCTAssertEqual(p.payment.getResultCallCount, 2, "one submit poll + one reconcile query")
        }

        /// `.unknown` auto-reconciles to a terminal failure: the sheet UNLOCKS back to editable with the
        /// failure notice, `present()` keeps running, and the next Pay is a FRESH submit (the marker is
        /// cleared, so Core does not gate it).
        @MainActor
        func test_autoReconcile_resolvesFailed_unlocksSheet_andFreshAttemptSubmits() async throws {
            let failed = PaymentSnapshot(sessionId: "sess_present", status: .failed, txnId: "txn_f")
            let ok = PaymentSnapshot(sessionId: "sess_present", status: .succeeded, txnId: "txn_new")
            let p = try await presentSheet(submit: [initialSnap, ok], getResult: [initialSnap, failed])
            defer { p.tearDown() }

            payWithSavedCard(p)
            try await waitUntil("reconciling") { p.content.currentViewState == .reconciling }
            try await waitUntil("unlock into failed") { self.isFailed(p.content.currentViewState) }

            XCTAssertTrue(p.content.isHomeInteractiveForTest, "a resolved failure must unlock inputs")
            XCTAssertTrue(p.content.isConfirmButtonVisibleForTest)
            XCTAssertTrue(p.content.isConfirmButtonEnabledForTest)
            XCTAssertTrue(p.content.isNoticeVisibleForTest, "the failure notice must be shown")
            XCTAssertEqual(p.payment.submitCallCount, 1)
            XCTAssertEqual(p.payment.getResultCallCount, 2)

            // Fresh attempt: submits again (new attemptId), no extra reconcile query.
            p.content.simulateTapPay()
            let outcome = await p.outcome()
            XCTAssertEqual(outcome, .succeeded(txnId: "txn_new"))
            XCTAssertEqual(p.payment.submitCallCount, 2, "the post-failure attempt is a fresh submit")
            XCTAssertEqual(p.payment.getResultCallCount, 2, "marker cleared: no reconcile gate on the fresh attempt")
        }

        /// A Pay tap that lands in the unlock window (the sheet is interactive again after a `.failed`,
        /// but the loop is still reloading the session and is not yet suspended in `awaitEvent`) must NOT
        /// be dropped: the tap is buffered and delivered to the next `awaitEvent`, so the second submit
        /// happens and `present()` resolves instead of sticking in `.processing` with ✕ disabled.
        @MainActor
        func test_tapDuringUnlockWindow_isBuffered_notDropped() async throws {
            let ok = PaymentSnapshot(sessionId: "sess_present", status: .succeeded, txnId: "txn_2")
            let failed = PaymentSnapshot(sessionId: "sess_present", status: .failed, txnId: "txn_1")
            let p = try await presentSheet(submit: [failed, ok], getResult: [])
            defer { p.tearDown() }

            // The reload that follows the failed attempt is slow, so the loop sits in `start` for a while.
            p.payment.stubLoadDelay(.milliseconds(700))
            payWithSavedCard(p)
            try await waitUntil("failed state") { self.isFailed(p.content.currentViewState) }
            XCTAssertEqual(p.payment.submitCallCount, 1)

            // Tap Pay inside the window: nobody is awaiting an action yet.
            p.content.simulateTapPay()

            let outcome = await p.outcome(within: 6)
            XCTAssertEqual(outcome, .succeeded(txnId: "txn_2"), "the buffered tap must reach the next attempt")
            XCTAssertEqual(p.payment.submitCallCount, 2)
        }

        /// A close landing while a tap is buffered still wins: `present()` resolves with the close
        /// result and the buffered tap is NOT submitted.
        @MainActor
        func test_closeWinsOverBufferedTap() async throws {
            let ok = PaymentSnapshot(sessionId: "sess_present", status: .succeeded, txnId: "txn_2")
            let failed = PaymentSnapshot(sessionId: "sess_present", status: .failed, txnId: "txn_1")
            let p = try await presentSheet(submit: [failed, ok], getResult: [])
            defer { p.tearDown() }

            // Gate the SECOND session (re)load — the one the retry loop performs after the first attempt
            // fails — so the loop deterministically parks there. (The first load, which presents the
            // sheet, is let through.) This replaces a wall-clock `stubLoadDelay` window: the race the
            // test checks is "a close observed while a tap is buffered wins over the buffered tap", and
            // the gate guarantees the loop is parked (tap buffered) BEFORE the close, with no timing luck.
            let gate = MockGate()
            let payment = p.payment
            payment.stubLoadGate { [weak payment] in
                // Only hold the reload (2nd+ load); the initial present already loaded once.
                if (payment?.loadSessionCallCount ?? 0) >= 2 { await gate.wait() }
            }

            payWithSavedCard(p)
            try await waitUntil("failed state") { self.isFailed(p.content.currentViewState) }

            // The loop is now re-entering the gated reload; wait until it is actually parked in the gate.
            await gate.untilEntered()

            p.content.simulateTapPay()                // buffered (loop is parked in the reload)
            p.container.onFinish?(.canceled)          // close observed before the loop resumes
            gate.release()                            // let the loop wake and re-enter awaitEvent

            let outcome = await p.outcome(within: 6)
            XCTAssertEqual(outcome, .canceled, "a close must win over a buffered tap")
            XCTAssertEqual(p.payment.submitCallCount, 1, "the buffered tap must not submit after a close")
        }

        /// Still `.unknown` after the reconcile: the sheet stays LOCKED (Pay hidden) but the notice
        /// switches to the "still confirming, you can close" message; ✕ works; `present()` returns the
        /// unresolved outcome on close.
        @MainActor
        func test_autoReconcile_stillUnknown_switchesNotice_staysLocked_closeReturnsUnknown() async throws {
            let p = try await presentSheet(submit: [initialSnap], getResult: [initialSnap])
            defer { p.tearDown() }

            payWithSavedCard(p)
            try await waitUntil("still-confirming notice") {
                p.content.noticeMessageForTest == "sunbay.notice.stillReconciling"
            }
            XCTAssertEqual(p.content.currentViewState, .reconciling, "must stay locked, not unlock")
            XCTAssertFalse(p.content.isConfirmButtonVisibleForTest, "Pay must stay hidden")
            XCTAssertTrue(p.content.isCloseInteractiveForTest)
            XCTAssertEqual(p.payment.submitCallCount, 1)
            XCTAssertEqual(p.payment.getResultCallCount, 2, "one submit poll + exactly one reconcile (no endless re-polling)")
            XCTAssertTrue(p.container.requestCancel(), "✕ must still work")

            let outcome = await p.outcome()
            XCTAssertEqual(outcome, .unknown(sessionId: "sess_present"))
        }

        /// Closing while the auto-reconcile is in flight cancels that task (it stops querying) and
        /// resolves `present()` exactly once with the unresolved outcome.
        @MainActor
        func test_closeDuringAutoReconcile_cancelsReconcile_resolvesOnce() async throws {
            let entered = LockedFlag()
            // Submit and its query-first fallback both fail → `.unknown` without touching the poller;
            // the ONLY poll is the reconcile, which then blocks in its sleep until cancelled.
            let p = try await presentSheet(
                submit: [], getResult: [],
                poller: { payment in
                    ResultPoller(
                        service: payment, config: PollConfig(initial: 1, max: 1, overallLimit: 90),
                        sleep: { _ in
                            entered.set()
                            try await Task.sleep(nanoseconds: 60 * 1_000_000_000)
                        })
                },
                configure: {
                    $0.stubSubmitError(URLError(.notConnectedToInternet))
                    $0.stubGetResultError(URLError(.notConnectedToInternet))
                })
            defer { p.tearDown() }

            payWithSavedCard(p)
            try await waitUntil("reconcile poll sleeping") { entered.isSet }
            XCTAssertEqual(p.content.currentViewState, .reconciling)
            let queriesBeforeClose = p.payment.getResultCallCount

            XCTAssertTrue(p.container.requestCancel(), "✕ must work while the reconcile is in flight")
            let start = Date()
            let outcome = await p.outcome(within: 5)
            XCTAssertLessThan(Date().timeIntervalSince(start), 3, "close must not wait for the poll to finish")
            XCTAssertEqual(outcome, .unknown(sessionId: "sess_present"))

            // The cancelled poll must stop (no further queries) and deliver nothing more.
            try await Task.sleep(nanoseconds: 200_000_000)
            XCTAssertEqual(p.payment.getResultCallCount, queriesBeforeClose, "cancelled reconcile must stop querying")
            XCTAssertEqual(p.payment.submitCallCount, 1)
        }

        // MARK: - F2: start failure inside the retry loop

        /// A session RE-load failing while an earlier attempt is unresolved (the sheet is locked) must not
        /// be applied to the content as a payment outcome: the VC stays locked, and `present()` returns the
        /// unresolved outcome when the user closes (not the start failure, not `.canceled`).
        @MainActor
        func test_startFailureWhileLocked_doesNotUnlock_returnsUnresolvedOutcome() async throws {
            let p = try await presentSheet(submit: [initialSnap], getResult: [initialSnap])
            defer { p.tearDown() }

            // The next (re)load, which the loop performs after the unsettled attempt, will fail.
            p.payment.stubLoadError(CheckoutErrors.networkUnavailable())
            payWithSavedCard(p)
            try await waitUntil("still-confirming notice") {
                p.content.noticeMessageForTest == "sunbay.notice.stillReconciling"
            }
            try await Task.sleep(nanoseconds: 300_000_000)

            XCTAssertEqual(p.content.currentViewState, .reconciling, "a start failure must not unlock the locked sheet")
            XCTAssertFalse(p.content.isConfirmButtonVisibleForTest)
            XCTAssertTrue(p.container.requestCancel())

            let outcome = await p.outcome()
            XCTAssertEqual(outcome, .unknown(sessionId: "sess_present"))
        }

        /// The very first session load failing never presents anything and `present()` returns that
        /// failure instead of spinning in the retry loop.
        @MainActor
        func test_firstLoadFailure_returnsFailure_doesNotHotLoop() async throws {
            let payment = MockPaymentService()
            payment.stubLoadError(CheckoutErrors.networkUnavailable())
            let controller = CheckoutController(
                paymentService: payment, cofService: MockCofService(), credentials: CredentialStore(),
                actionHandler: StubActionHandler(result: .pending), poller: makeZeroWaitPoller(payment))
            let sheet = PaymentSheet(controller: controller, sessionId: "sess_present", customerAccessSecret: nil)
            let root = UIViewController()
            let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 844))
            window.rootViewController = root
            window.makeKeyAndVisible()
            defer { window.isHidden = true; window.rootViewController = nil }

            let task = Task { @MainActor in await sheet.present(from: root) }
            let box = OutcomeBox()
            Task { box.set(await task.value) }
            let deadline = Date().addingTimeInterval(3)
            while box.value == nil, Date() < deadline {
                try await Task.sleep(nanoseconds: 20_000_000)
            }

            guard let outcome = box.value else {
                return XCTFail("present() did not return within 3s: the retry loop is spinning on a start failure")
            }
            guard case let .failed(_, error) = outcome else {
                return XCTFail("expected the start failure, got \(outcome)")
            }
            XCTAssertEqual(error.code, "NETWORK_UNAVAILABLE")
            XCTAssertLessThanOrEqual(payment.loadSessionCallCount, 2, "must not hammer the backend with reloads")
        }

        /// A reload failing while the sheet is merely editable (after a confirmed `.failed`) ends the
        /// presentation with the start failure; it neither spins nor leaves the sheet hanging.
        @MainActor
        func test_reloadFailureAfterConfirmedFailure_endsWithStartFailure() async throws {
            let failed = PaymentSnapshot(sessionId: "sess_present", status: .failed, txnId: "t1")
            let p = try await presentSheet(submit: [failed], getResult: [])
            defer { p.tearDown() }

            p.payment.stubLoadError(CheckoutErrors.networkUnavailable())
            payWithSavedCard(p)

            guard let outcome = await p.outcome(within: 5) else {
                return XCTFail("present() did not return: the loop is spinning on the reload failure")
            }
            guard case let .failed(_, error) = outcome else {
                return XCTFail("expected the start failure, got \(outcome)")
            }
            XCTAssertEqual(error.code, "NETWORK_UNAVAILABLE")
            XCTAssertLessThanOrEqual(p.payment.loadSessionCallCount, 3)
        }

        // MARK: - onStateChange bridge

        /// The container forwards the content's `didChangeState` to its `onStateChange` callback,
        /// which `PaymentSheet` wires to the public `onStateChange`.
        @MainActor
        func test_container_forwardsStateChangeToOnStateChange() {
            let session = makeSession(id: "sess_state_1", cofEnabled: false)
            let content = CheckoutContentViewController(
                session: session,
                savedCards: [],
                appearance: .resolve(.default),
                localize: { $0 },
                billingMode: .simple,
                shippingMode: .simple,
                addressService: EmptyAddressMetadataService()
            )
            let container = PaymentSheetContainerViewController(
                content: content,
                appearance: .resolve(.default),
                colorScheme: .automatic
            )

            var observed: CheckoutPresentationState?
            container.onStateChange = { observed = $0 }

            // The container is the content's delegate; drive a confirm so the content emits a state.
            // The new-card form is a subpage now, so open it before filling/tapping Pay.
            content.loadViewIfNeeded()
            content.openNewCardForTest()
            content.fillCardForTest()
            content.simulateTapPay()

            XCTAssertEqual(observed, .processing)
        }
    }
#endif
