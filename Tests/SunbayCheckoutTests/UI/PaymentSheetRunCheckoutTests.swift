#if canImport(UIKit)
    import UIKit
    import XCTest

    @testable import SunbayCheckout

    /// Coverage for the `PaymentSheet` attempt loop plus the container's state bridge.
    ///
    /// ## Where the loop lives
    /// `present()` loads the session once (`loadContext`) and then drives each user action through the
    /// presentation coordinator and `execute` (one confirm → one outcome). Non-terminal outcomes
    /// (`.failed` / `.pending` / `.unknown`) keep the content open; the next confirm drives another attempt.
    /// `runCheckout(seam:)` stays single-shot (load + one seam call + one confirm) and is exercised
    /// headlessly here, like `PaymentSheetTests`. The `presentSheet` tests drive the real sheet over a
    /// test window.
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

        // MARK: - Effective COF decision

        private func runOnce(
            options: CardOnFileOptions, secret: String?
        ) async -> (MockCofService, PaymentSheet.CheckoutContext?) {
            let sessionId = "sess_cof_decision"
            let payment = MockPaymentService()
            payment.stubSession(makeSession(id: sessionId, cofEnabled: true))
            let cof = MockCofService()
            cof.stubCards([SavedCard(id: "pm_1", brand: "visa", last4: "4242", expMonth: 12, expYear: 2030)])
            let controller = CheckoutController(
                paymentService: payment, cofService: cof, credentials: CredentialStore(),
                actionHandler: StubActionHandler(result: .pending), cardOnFile: options)
            let sheet = PaymentSheet(controller: controller, sessionId: sessionId, customerAccessSecret: secret)
            let captured = ContextBox()
            _ = await sheet.runAttempt { context in
                captured.value = context
                return .cancel
            }
            return (cof, captured.value)
        }

        private final class ContextBox: @unchecked Sendable {
            var value: PaymentSheet.CheckoutContext?
        }

        func test_cardOnFileDisabled_listsNoCards_andContextReflectsIt() async {
            let (cof, context) = await runOnce(options: CardOnFileOptions(isEnabled: false), secret: "secret_abc")
            XCTAssertEqual(cof.listCallCount, 0)
            XCTAssertEqual(context?.cardOnFileEnabled, false)
            XCTAssertEqual(context?.savedCards.count, 0)
        }

        func test_defaultOptionsWithSecret_listsOnce_andContextCarriesDecision() async {
            let (cof, context) = await runOnce(
                options: CardOnFileOptions(saveByDefault: true), secret: "secret_abc")
            XCTAssertEqual(cof.listCallCount, 1)
            XCTAssertEqual(context?.cardOnFileEnabled, true)
            XCTAssertEqual(context?.saveCardByDefault, true)
            XCTAssertEqual(context?.savedCards.count, 1)
        }

        func test_noSecret_listsNothing_andCofIsOff() async {
            let (cof, context) = await runOnce(options: CardOnFileOptions(), secret: nil)
            XCTAssertEqual(cof.listCallCount, 0)
            XCTAssertEqual(context?.cardOnFileEnabled, false)
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

        /// Presents the real sheet over a test window; returns what's needed to drive it. The localizer
        /// is the identity so notices can be asserted by key.
        @MainActor
        private func presentSheet(
            submit: [PaymentSnapshot], getResult: [PaymentSnapshot],
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
                actionHandler: StubActionHandler(result: .pending)
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
        /// A `.unknown` attempt (submit throws, the one-shot query also throws) followed by the user
        /// closing the sheet: `present()` returns `.unknown` (so the host calls `retrievePayment()`),
        /// NOT `.canceled`.
        @MainActor
        func test_present_closeAfterUnknown_returnsUnknown_notCanceled() async throws {
            let p = try await presentSheet(submit: [], getResult: []) {
                $0.stubSubmitError(URLError(.notConnectedToInternet))
                $0.stubGetResultError(URLError(.notConnectedToInternet))
            }
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

        // MARK: - Pending / unknown (no client polling)

        /// `.unknown` locks the sheet with the neutral "you can close" notice and the SDK does NOT poll;
        /// the user closes and `present()` returns `.unknown` for the host to reconcile.
        @MainActor
        func test_pending_locksSheet_showsNotice_noPolling_closeReturnsUnknown() async throws {
            let p = try await presentSheet(submit: [initialSnap], getResult: [])
            defer { p.tearDown() }

            payWithSavedCard(p)
            try await waitUntil("reconciling") { p.content.currentViewState == .reconciling }
            try await waitUntil("confirming notice") {
                p.content.noticeMessageForTest == "sunbay.notice.reconciling"
            }
            XCTAssertFalse(p.content.isConfirmButtonVisibleForTest, "Pay stays hidden while unsettled")
            XCTAssertTrue(p.content.isCloseInteractiveForTest, "✕ must work")
            XCTAssertEqual(p.payment.submitCallCount, 1)
            XCTAssertEqual(p.payment.getResultCallCount, 0, "the SDK must NOT poll for the result")

            XCTAssertTrue(p.container.requestCancel())
            let outcome = await p.outcome()
            XCTAssertEqual(outcome, .pending(txnId: nil))
        }

        // MARK: - Buffered user action (unlock window after a .failed)

        /// A Pay tap right after a `.failed` (the sheet is interactive again, possibly before the loop is
        /// suspended in `awaitEvent`) must NOT be dropped: it is buffered or delivered, so the second submit
        /// happens and `present()` resolves instead of sticking in `.processing` with ✕ disabled.
        @MainActor
        func test_tapDuringUnlockWindow_isBuffered_notDropped() async throws {
            let ok = PaymentSnapshot(sessionId: "sess_present", status: .succeeded, txnId: "txn_2")
            let failed = PaymentSnapshot(sessionId: "sess_present", status: .failed, txnId: "txn_1")
            let p = try await presentSheet(submit: [failed, ok], getResult: [])
            defer { p.tearDown() }

            payWithSavedCard(p)
            try await waitUntil("failed state") { self.isFailed(p.content.currentViewState) }
            XCTAssertEqual(p.payment.submitCallCount, 1)

            // A tap right after the failure submits attempt 2.
            p.content.simulateTapPay()

            let outcome = await p.outcome(within: 6)
            XCTAssertEqual(outcome, .succeeded(txnId: "txn_2"), "a tap right after a failure must reach the next attempt")
            XCTAssertEqual(p.payment.submitCallCount, 2)
        }

        /// A confirmed failure keeps the sheet open and does NOT reload the session; the user retries.
        @MainActor
        func test_failedConfirm_keepsSheetOpen_andDoesNotReloadSession() async throws {
            let ok = PaymentSnapshot(sessionId: "sess_present", status: .succeeded, txnId: "txn_2")
            let failed = PaymentSnapshot(sessionId: "sess_present", status: .failed, txnId: "txn_1")
            let p = try await presentSheet(submit: [failed, ok], getResult: [])
            defer { p.tearDown() }

            payWithSavedCard(p)
            try await waitUntil("failed state") { self.isFailed(p.content.currentViewState) }
            try await Task.sleep(nanoseconds: 200_000_000)
            XCTAssertEqual(p.payment.loadSessionCallCount, 1, "a failed confirm must not reload the session")

            p.content.simulateTapPay()
            let outcome = await p.outcome(within: 6)
            XCTAssertEqual(outcome, .succeeded(txnId: "txn_2"))
            XCTAssertEqual(p.payment.submitCallCount, 2)
        }

        /// Even if a reload would fail, the failed state stays on screen (no reload happens at all).
        @MainActor
        func test_failedConfirm_thenLoadWouldFail_stillKeepsSheetOpen() async throws {
            let failed = PaymentSnapshot(sessionId: "sess_present", status: .failed, txnId: "txn_1")
            let p = try await presentSheet(submit: [failed], getResult: [])
            defer { p.tearDown() }

            p.payment.stubLoadError(CheckoutErrors.networkUnavailable())
            payWithSavedCard(p)
            try await waitUntil("failed state") { self.isFailed(p.content.currentViewState) }
            try await Task.sleep(nanoseconds: 300_000_000)

            XCTAssertTrue(isFailed(p.content.currentViewState), "the sheet must still show the failed state")
            XCTAssertTrue(p.container.requestCancel())
            let outcome = await p.outcome()
            XCTAssertEqual(outcome, .canceled)
        }

        /// A close landing while a tap is buffered still wins: `present()` resolves with the close
        /// result and the buffered tap is NOT submitted.
        @MainActor
        func test_closeWinsOverBufferedTap() async throws {
            let ok = PaymentSnapshot(sessionId: "sess_present", status: .succeeded, txnId: "txn_2")
            let failed = PaymentSnapshot(sessionId: "sess_present", status: .failed, txnId: "txn_1")
            let p = try await presentSheet(submit: [failed, ok], getResult: [])
            defer { p.tearDown() }

            payWithSavedCard(p)
            try await waitUntil("failed state") { self.isFailed(p.content.currentViewState) }

            // A close right after a failure ends the presentation as a cancel and submits nothing more.
            p.container.onFinish?(.canceled)

            let outcome = await p.outcome(within: 6)
            XCTAssertEqual(outcome, .canceled, "a close after a failure is a genuine cancel")
            XCTAssertEqual(p.payment.submitCallCount, 1, "nothing is submitted after a close")
        }

        // MARK: - Host-provided addresses

        /// A complete host `billingAddress` / `shippingAddress` on a session that collects them reaches the submit request even though the SDK
        /// forms are off and the action carries no form values.
        @MainActor
        func test_hostAddresses_reachSubmit_withoutFormValues() async throws {
            let sessionId = "sess_host_addr"
            let key = try PaymentSheetTests.makeRSAPublicKeyBase64(bits: 2048)
            let session = CheckoutSession(
                id: sessionId, amount: Amount(minorUnits: 999, currencyCode: "USD"), merchantName: "Acme",
                methods: [.card], expiresAt: Date().addingTimeInterval(600), rsaPublicKey: key, cofEnabled: false,
                collectBillingAddress: true, collectShippingAddress: true)
            let (controller, payment, _) = makeController(
                session: session, cards: [],
                submit: [PaymentSnapshot(sessionId: sessionId, status: .succeeded, txnId: "txn_ok")])
            let host = AddressInput(country: "US", line1: "1 Main", city: "SF", postalCode: "94103")
            let ship = AddressInput(
                country: "CA", line1: "2 Side", city: "Toronto", postalCode: "M5V",
                firstName: "Ada", lastName: "Lovelace", phone: "5551234")
            let sheet = PaymentSheet(
                controller: controller, sessionId: sessionId, billingAddress: host, shippingAddress: ship)
            let card = CardInput(cardNumber: "4242424242424242", expiryMonth: "12", expiryYear: "2030", cvv: "123")

            let outcome = await sheet.runCheckout { _ in .confirmNewCard(card, save: false) }

            guard case .succeeded = outcome else { return XCTFail("expected .succeeded, got \(outcome)") }
            XCTAssertEqual(payment.lastSubmitRequest?.billingAddress, host)
            XCTAssertEqual(payment.lastSubmitRequest?.shippingAddress, ship)
        }

        private final class DiagnosticCodes: @unchecked Sendable {
            private let lock = NSLock()
            private var items: [String] = []
            func add(_ d: CheckoutDiagnostic) {
                if case let .warning(w) = d { lock.lock(); items.append(w.code.rawValue); lock.unlock() }
            }
            var codes: [String] { lock.lock(); defer { lock.unlock() }; return items }
        }

        // MARK: - Reconciling lock and first-load failure

        /// A pending attempt locks the sheet without any session reload; closing returns the unresolved
        /// outcome (not `.canceled`).
        @MainActor
        func test_pendingConfirm_doesNotReload_closeReturnsPending() async throws {
            let p = try await presentSheet(submit: [initialSnap], getResult: [initialSnap])
            defer { p.tearDown() }

            payWithSavedCard(p)
            try await waitUntil("confirming notice") {
                p.content.noticeMessageForTest == "sunbay.notice.reconciling"
            }
            try await Task.sleep(nanoseconds: 300_000_000)

            XCTAssertEqual(p.content.currentViewState, .reconciling, "a pending outcome must keep the sheet locked in reconciling (no reload, no unlock)")
            XCTAssertFalse(p.content.isConfirmButtonVisibleForTest)
            XCTAssertTrue(p.container.requestCancel())

            let outcome = await p.outcome()
            XCTAssertEqual(outcome, .pending(txnId: nil))
        }

        /// The very first session load failing never presents anything and `present()` returns that
        /// failure instead of spinning in the retry loop.
        @MainActor
        func test_firstLoadFailure_returnsFailure_doesNotHotLoop() async throws {
            let payment = MockPaymentService()
            payment.stubLoadError(CheckoutErrors.networkUnavailable())
            let controller = CheckoutController(
                paymentService: payment, cofService: MockCofService(), credentials: CredentialStore(),
                actionHandler: StubActionHandler(result: .pending))
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
            // The fallback address config requires line1 and a postal code, so fill the loaded forms before Pay.
            for form in [content.billingAddressViewForTest, content.shippingAddressViewForTest] {
                (form as? DynamicAddressFormView)?.setTextForTest(.line1, "1 Main St")
                (form as? DynamicAddressFormView)?.setPostalCodeForTest("94103")
            }
            content.simulateTapPay()

            XCTAssertEqual(observed, .processing)
        }
    }
#endif

#if canImport(UIKit)
    @testable import SunbayCheckout

    /// Payment-method filter behavior of `PaymentSheet` (registry, empty result, saved-card listing).
    final class PaymentSheetMethodFilterTests: XCTestCase {
        private final class Box: @unchecked Sendable {
            var context: PaymentSheet.CheckoutContext?
            var warnings: [CheckoutWarning] = []
        }

        private func makeSession(methods: Set<PaymentMethodKind>) -> CheckoutSession {
            CheckoutSession(
                id: "sess_filter", amount: Amount(minorUnits: 999, currencyCode: "USD"), merchantName: "Acme",
                methods: methods, expiresAt: Date().addingTimeInterval(600), cofEnabled: true)
        }

        private func makeSheet(
            methods: Set<PaymentMethodKind> = [.card, .applePay], filter: PaymentMethodFilter,
            reporter: DiagnosticsReporter? = nil, missingWalletParams: [String] = []
        ) -> (PaymentSheet, MockCofService) {
            let payment = MockPaymentService()
            payment.stubSession(makeSession(methods: methods))
            let cof = MockCofService()
            cof.stubCards([SavedCard(id: "pm_1", brand: "visa", last4: "4242", expMonth: 12, expYear: 2030)])
            let controller = CheckoutController(
                paymentService: payment, cofService: cof, credentials: CredentialStore(),
                actionHandler: StubActionHandler(result: .pending), reporter: reporter)
            let sheet = PaymentSheet(
                controller: controller, sessionId: "sess_filter", customerAccessSecret: "secret",
                walletAuthorizer: MockWalletAuthorizer(
                    canMake: true, outcome: .success(Data([1])), missing: missingWalletParams),
                walletMerchantId: "merchant.com.acme", paymentMethodFilter: filter)
            return (sheet, cof)
        }

        private func run(_ sheet: PaymentSheet) async -> (PaymentSheet.AttemptResult, PaymentSheet.CheckoutContext?) {
            let box = Box()
            let result = await sheet.runAttempt { context in
                box.context = context
                return .cancel
            }
            return (result, box.context)
        }

        private func walletWarnings(_ box: Box) -> [CheckoutWarning] {
            box.warnings.filter { $0.code == .walletParamsInvalid }
        }

        private func recordingReporter(_ box: Box) -> DiagnosticsReporter {
            let reporter = DiagnosticsReporter()
            reporter.handler = { if case let .warning(w) = $0 { box.warnings.append(w) } }
            return reporter
        }

        func test_applePayOnly_withBadWalletParams_failsAndReportsWalletParamsInvalidOnce() async {
            let box = Box()
            let (sheet, _) = makeSheet(
                methods: [.applePay], filter: PaymentMethodFilter(), reporter: recordingReporter(box),
                missingWalletParams: ["supportedNetworks"])
            let (result, _) = await run(sheet)
            guard case let .startFailed(.failed(_, error)) = result else { return XCTFail("expected start failure") }
            XCTAssertEqual(error.code, "NO_PAYMENT_METHOD_AVAILABLE")
            await MainActor.run {}
            XCTAssertEqual(walletWarnings(box).count, 1)
            XCTAssertEqual(walletWarnings(box).first?.ignored, ["supportedNetworks"])
        }

        func test_cardAndApplePay_withBadWalletParams_reportsExactlyOneWarning() async {
            let box = Box()
            let (sheet, _) = makeSheet(
                filter: PaymentMethodFilter(), reporter: recordingReporter(box),
                missingWalletParams: ["merchantCapabilities"])
            let (_, context) = await run(sheet)
            XCTAssertEqual(context?.visibleEntries.map(\.method), ["CARD", "APPLE_PAY"])
            await MainActor.run {}
            XCTAssertEqual(walletWarnings(box).count, 1)
        }

        func test_badWalletParams_withApplePayHidden_reportsNothing() async {
            let box = Box()
            let (sheet, _) = makeSheet(
                filter: PaymentMethodFilter(hide: ["APPLE_PAY"]), reporter: recordingReporter(box),
                missingWalletParams: ["supportedNetworks"])
            _ = await run(sheet)
            await MainActor.run {}
            XCTAssertTrue(walletWarnings(box).isEmpty)
        }

        func test_hideApplePay_keepsCardOnly() async {
            let (sheet, _) = makeSheet(filter: PaymentMethodFilter(hide: ["APPLE_PAY"]))
            let (_, context) = await run(sheet)
            XCTAssertEqual(context?.visibleEntries.map(\.method), ["CARD"])
        }

        func test_hideCard_skipsSavedCardListing_andKeepsApplePay() async {
            let (sheet, cof) = makeSheet(filter: PaymentMethodFilter(hide: ["CARD"]))
            let (_, context) = await run(sheet)
            XCTAssertEqual(cof.listCallCount, 0)
            XCTAssertEqual(context?.savedCards.count, 0)
            XCTAssertEqual(context?.visibleEntries.map(\.method), ["APPLE_PAY"])
        }

        func test_hideEverything_failsWithNoPaymentMethodAvailable_andPresentsNothing() async {
            let (sheet, _) = makeSheet(filter: PaymentMethodFilter(hide: ["CARD", "APPLE_PAY"]))
            let presenter = await MainActor.run { UIViewController() }
            let outcome = await sheet.present(from: presenter)
            guard case let .failed(_, error) = outcome else { return XCTFail("expected .failed, got \(outcome)") }
            XCTAssertEqual(error.code, "NO_PAYMENT_METHOD_AVAILABLE")
            XCTAssertEqual(error.category, .configuration)
            let presented = await MainActor.run { presenter.presentedViewController }
            XCTAssertNil(presented)
        }

        func test_sessionWithoutCardEntry_hidingApplePay_failsInsteadOfDefaultingToCard() async {
            let (sheet, _) = makeSheet(methods: [.applePay], filter: PaymentMethodFilter(hide: ["APPLE_PAY"]))
            let (result, _) = await run(sheet)
            guard case let .startFailed(.failed(_, error)) = result else { return XCTFail("expected start failure") }
            XCTAssertEqual(error.code, "NO_PAYMENT_METHOD_AVAILABLE")
        }

        func test_unknownIdentifiers_areReportedOncePerIdentifier() async {
            let reporter = DiagnosticsReporter()
            let box = Box()
            reporter.handler = { if case let .warning(w) = $0 { box.warnings.append(w) } }
            let (sheet, _) = makeSheet(
                filter: PaymentMethodFilter(hide: ["nope", "nope"], order: ["GOOGLE_PAY"]), reporter: reporter)
            _ = await run(sheet)
            _ = await run(sheet)
            await MainActor.run {}
            XCTAssertEqual(box.warnings.map(\.code), [.paymentMethodFilterIgnored, .paymentMethodFilterIgnored])
            XCTAssertEqual(box.warnings.flatMap(\.ignored), ["nope", "GOOGLE_PAY"])
        }
    }
#endif
