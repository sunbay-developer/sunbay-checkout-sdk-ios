import Foundation
import Security
import XCTest

@testable import SunbayCheckout

/// Orchestration / state-machine / invariant tests for `CheckoutController` (Task 6 Step 1).
///
/// Covers the concurrency and idempotency invariants in product-spec §4.2: single active session,
/// one attemptId per click, query-before-blindly-resubmitting on submit failure, result dedup,
/// clearing credentials on terminal state; plus the submit-field differences across the three paths.
final class CheckoutControllerTests: XCTestCase {
    // MARK: - Fixtures

    /// Builds a non-expired session that allows new card/wallet and optionally COF.
    private func makeSession(
        id: String = "sess_1",
        cofEnabled: Bool = true,
        rsaPublicKey: String? = nil,
        expiresAt: Date = Date().addingTimeInterval(600)
    ) -> CheckoutSession {
        CheckoutSession(
            id: id,
            amount: Amount(minorUnits: 999, currencyCode: "USD"),
            merchantName: "Acme",
            methods: [.card, .applePay],
            expiresAt: expiresAt,
            rsaPublicKey: rsaPublicKey,
            cofEnabled: cofEnabled
        )
    }

    private func terminalSucceeded(
        sessionId: String = "sess_1",
        txnId: String = "txn_1"
    ) -> PaymentSnapshot {
        PaymentSnapshot(sessionId: sessionId, status: .succeeded, txnId: txnId)
    }

    private func makeController(
        payment: MockPaymentService,
        cof: MockCofService = MockCofService(),
        credentials: CredentialStore = CredentialStore(),
        actionHandler: StubActionHandler = StubActionHandler(),
        poller: ResultPoller? = nil,
        pendingStore: PendingReconciliationStore = PendingReconciliationStore()
    ) -> CheckoutController {
        CheckoutController(
            paymentService: payment,
            cofService: cof,
            credentials: credentials,
            actionHandler: actionHandler,
            poller: poller,
            pendingStore: pendingStore
        )
    }

    /// Builds a poller backed by the injected payment and a "zero-wait" sleep, so the controller
    /// can poll deterministically to a terminal state without any real sleeping when `.initial` (pending).
    private func noWaitPoller(payment: MockPaymentService) -> ResultPoller {
        ResultPoller(
            service: payment,
            config: PollConfig(initial: 0.001, max: 0.001, overallLimit: 0.05),
            sleep: { _ in }
        )
    }

    private func newCardInput() -> CardInput {
        CardInput(cardNumber: "4242424242424242", expiryMonth: "12", expiryYear: "2029", cvv: "123")
    }

    /// Generates a 2048-bit RSA public key (base64 of PKCS#1 DER) so `CardEncryptor` can actually encrypt.
    private func makeRSAPublicKey() throws -> String {
        let attributes: [String: Any] = [
            kSecAttrKeyType as String: kSecAttrKeyTypeRSA,
            kSecAttrKeySizeInBits as String: 2048,
        ]
        var error: Unmanaged<CFError>?
        guard let priv = SecKeyCreateRandomKey(attributes as CFDictionary, &error) else {
            throw error!.takeRetainedValue() as Error
        }
        guard let pub = SecKeyCopyPublicKey(priv),
              let der = SecKeyCopyExternalRepresentation(pub, &error) as Data?
        else {
            throw NSError(domain: "CheckoutControllerTests", code: -1)
        }
        return der.base64EncodedString()
    }

    // MARK: - Invariant: single active session

    func test_singleActiveSession_secondConfirmReturnsAlreadyPresenting() async throws {
        let payment = MockPaymentService()
        payment.stubSession(makeSession())
        payment.stubSubmit([terminalSucceeded()])
        payment.stubSubmitDelay(.milliseconds(300)) // keep the first confirm in flight

        let controller = makeController(payment: payment)
        _ = try await controller.start(sessionId: "sess_1", customerAccessSecret: nil)

        async let first = controller.confirmSavedCard(paymentMethodId: "pm_1")
        // Give the first confirm a moment to go in flight (holding the active lock).
        try await Task.sleep(for: .milliseconds(50))
        async let second = controller.confirmSavedCard(paymentMethodId: "pm_2")

        let (r1, r2) = await (first, second)

        // Exactly one succeeds, one returns alreadyPresenting.
        let outcomes = [r1, r2]
        let succeededCount = outcomes.filter { if case .succeeded = $0 { return true }; return false }.count
        let presentingCount = outcomes.filter {
            if case .failed(_, let err) = $0 { return err.code == "ALREADY_PRESENTING" }
            return false
        }.count

        XCTAssertEqual(succeededCount, 1, "exactly one confirm should succeed")
        XCTAssertEqual(presentingCount, 1, "the second concurrent confirm should return alreadyPresenting")
        XCTAssertEqual(payment.submitCallCount, 1, "the second confirm must not submit again")
    }

    // MARK: - Invariant: query before resubmitting on submit failure, never blindly resend

    func test_submitTimeout_queriesResult_neverResubmits() async throws {
        let payment = MockPaymentService()
        payment.stubSession(makeSession())
        payment.stubSubmitError(URLError(.timedOut))
        payment.stubGetResult([terminalSucceeded(txnId: "txn_query")])

        let controller = makeController(payment: payment)
        _ = try await controller.start(sessionId: "sess_1", customerAccessSecret: nil)

        let outcome = await controller.confirmSavedCard(paymentMethodId: "pm_1")

        XCTAssertEqual(payment.submitCallCount, 1, "submit should happen only once")
        XCTAssertEqual(payment.getResultCallCount, 1, "should query once after submit fails")
        if case .succeeded(let txnId) = outcome {
            XCTAssertEqual(txnId, "txn_query", "should map the snapshot from getResult")
        } else {
            XCTFail("should map the success snapshot returned by getResult, got: \(outcome)")
        }
    }

    func test_submitFails_andGetResultFails_mapsToUnknown() async throws {
        let payment = MockPaymentService()
        payment.stubSession(makeSession())
        payment.stubSubmitError(URLError(.timedOut))
        payment.stubGetResultError(URLError(.notConnectedToInternet))

        let controller = makeController(payment: payment)
        _ = try await controller.start(sessionId: "sess_1", customerAccessSecret: nil)

        let outcome = await controller.confirmSavedCard(paymentMethodId: "pm_1")

        XCTAssertEqual(payment.submitCallCount, 1)
        XCTAssertEqual(payment.getResultCallCount, 1)
        if case .unknown(let sessionId) = outcome {
            XCTAssertEqual(sessionId, "sess_1")
        } else {
            XCTFail("both submit and getResult failing should map to unknown, got: \(outcome)")
        }
    }

    // MARK: - Invariant: result dedup (terminal state delivered only once)

    func test_duplicateTerminalResult_deliveredOnce() async throws {
        let payment = MockPaymentService()
        payment.stubSession(makeSession())
        // Script two identical terminal snapshots for the same attempt; one confirm consumes one and delivers once.
        payment.stubSubmit([terminalSucceeded(), terminalSucceeded()])

        let controller = makeController(payment: payment)
        _ = try await controller.start(sessionId: "sess_1", customerAccessSecret: nil)

        let outcome = await controller.confirmSavedCard(paymentMethodId: "pm_1")

        XCTAssertEqual(payment.submitCallCount, 1, "one confirm submits only once")
        if case .succeeded = outcome {} else {
            XCTFail("should deliver success once, got: \(outcome)")
        }
        // The active lock should be released: a second confirm is not blocked by alreadyPresenting.
        let again = await controller.confirmSavedCard(paymentMethodId: "pm_1")
        if case .failed(_, let err) = again, err.code == "ALREADY_PRESENTING" {
            XCTFail("the active lock should be released after a terminal state")
        }
    }

    // MARK: - New card: encrypt and submit

    func test_newCard_encryptsAndSubmits() async throws {
        let rsaKey = try makeRSAPublicKey()
        let payment = MockPaymentService()
        payment.stubSession(makeSession(rsaPublicKey: rsaKey))
        payment.stubSubmit([terminalSucceeded()])

        let controller = makeController(payment: payment)
        _ = try await controller.start(sessionId: "sess_1", customerAccessSecret: nil)

        _ = await controller.confirmNewCard(newCardInput(), save: false, consent: nil)

        let req = try XCTUnwrap(payment.lastSubmitRequest)
        XCTAssertNotNil(req.cardEncryptedData)
        XCTAssertFalse(req.cardEncryptedData?.isEmpty ?? true, "a new card should carry non-empty ciphertext")
        XCTAssertNil(req.paymentMethodId, "a new card must not carry paymentMethodId")
        XCTAssertNil(req.walletToken)
    }

    // MARK: - Saved card: carry only paymentMethodId, no card data

    func test_savedCard_submitsPaymentMethodId_noCardData() async throws {
        let payment = MockPaymentService()
        payment.stubSession(makeSession())
        payment.stubSubmit([terminalSucceeded()])

        let controller = makeController(payment: payment)
        _ = try await controller.start(sessionId: "sess_1", customerAccessSecret: nil)

        _ = await controller.confirmSavedCard(paymentMethodId: "pm_42")

        let req = try XCTUnwrap(payment.lastSubmitRequest)
        XCTAssertEqual(req.paymentMethodId, "pm_42")
        XCTAssertNil(req.cardEncryptedData, "a saved card must not carry card ciphertext")
        XCTAssertNil(req.walletToken)
    }

    // MARK: - COF disabled: saved-card list is empty and CofService is not called

    func test_cofDisabled_listSavedCardsEmpty() async throws {
        let payment = MockPaymentService()
        payment.stubSession(makeSession(cofEnabled: false))
        let cof = MockCofService()
        cof.stubCards([SavedCard(id: "pm_1", brand: "visa", last4: "4242", expMonth: 12, expYear: 2029)])

        let controller = makeController(payment: payment, cof: cof)
        _ = try await controller.start(sessionId: "sess_1", customerAccessSecret: "secret_abc")

        let cards = await controller.listSavedCards()

        XCTAssertTrue(cards.isEmpty, "COF disabled should return an empty list")
        XCTAssertEqual(cof.listCallCount, 0, "CofService must never be called when COF is disabled")
    }

    func test_cofListThrows_degradesToEmpty() async throws {
        let payment = MockPaymentService()
        payment.stubSession(makeSession(cofEnabled: true))
        let cof = MockCofService()
        cof.stubError(URLError(.badServerResponse))

        let controller = makeController(payment: payment, cof: cof)
        _ = try await controller.start(sessionId: "sess_1", customerAccessSecret: "secret_abc")

        let cards = await controller.listSavedCards()

        XCTAssertTrue(cards.isEmpty, "a failed card listing should degrade to empty, not throw")
        XCTAssertEqual(cof.listCallCount, 1)
    }

    // MARK: - Terminal state clears credentials

    func test_terminalState_clearsCredentials() async throws {
        let payment = MockPaymentService()
        payment.stubSession(makeSession())
        payment.stubSubmit([terminalSucceeded()])
        let credentials = CredentialStore()

        let controller = makeController(payment: payment, credentials: credentials)
        _ = try await controller.start(sessionId: "sess_1", customerAccessSecret: "secret_abc")

        await credentials.hold(customerAccessSecret: "secret_abc")
        let before = await credentials.current()
        XCTAssertNotNil(before)

        _ = await controller.confirmSavedCard(paymentMethodId: "pm_1")

        let held = await credentials.current()
        XCTAssertNil(held, "credentials should be cleared after a terminal state")
    }

    // MARK: - start: an expired session should throw

    func test_start_expiredSession_throws() async throws {
        let payment = MockPaymentService()
        payment.stubSession(makeSession(expiresAt: Date().addingTimeInterval(-10)))

        let controller = makeController(payment: payment)

        do {
            _ = try await controller.start(sessionId: "sess_1", customerAccessSecret: nil)
            XCTFail("an expired session should throw")
        } catch let error as CheckoutError {
            XCTAssertEqual(error.category, .validation)
        }
    }

    // MARK: - requiresAction (R) → delegate to ActionHandler

    func test_requiresAction_delegatesToActionHandler_pending() async throws {
        let payment = MockPaymentService()
        payment.stubSession(makeSession())
        payment.stubSubmit([PaymentSnapshot(sessionId: "sess_1", status: .requiresAction, txnId: "txn_r")])
        payment.stubNextAction(.redirect(url: URL(string: "https://psp.example/redirect")!))
        let action = StubActionHandler(result: .pending)

        let controller = makeController(payment: payment, actionHandler: action)
        _ = try await controller.start(sessionId: "sess_1", customerAccessSecret: nil)

        let outcome = await controller.confirmSavedCard(paymentMethodId: "pm_1")

        XCTAssertEqual(action.handleCallCount, 1)
        XCTAssertEqual(action.lastAction, .redirect(url: URL(string: "https://psp.example/redirect")!))
        if case .pending(let txnId) = outcome {
            XCTAssertEqual(txnId, "txn_r")
        } else {
            XCTFail("R + handler .pending should map to pending, got: \(outcome)")
        }
    }

    func test_requiresAction_actionHandlerFailed_mapsFailed() async throws {
        let payment = MockPaymentService()
        payment.stubSession(makeSession())
        payment.stubSubmit([PaymentSnapshot(sessionId: "sess_1", status: .requiresAction, txnId: "txn_r")])
        payment.stubNextAction(.qrCode)
        let failErr = CheckoutError(code: "UNSUPPORTED_CAPABILITY", message: "x", category: .runtime, traceId: nil)
        let action = StubActionHandler(result: .failed(failErr))

        let controller = makeController(payment: payment, actionHandler: action)
        _ = try await controller.start(sessionId: "sess_1", customerAccessSecret: nil)

        let outcome = await controller.confirmSavedCard(paymentMethodId: "pm_1")

        if case .failed(let txnId, let err) = outcome {
            XCTAssertEqual(txnId, "txn_r")
            XCTAssertEqual(err.code, "UNSUPPORTED_CAPABILITY")
        } else {
            XCTFail("R + handler .failed should map to failed, got: \(outcome)")
        }
    }

    /// A client-side action-handler failure (e.g. UNSUPPORTED_CAPABILITY) is NOT a server-confirmed
    /// terminal failure: the server transaction is still `R` (confirmed). The outcome stays `.failed`
    /// (public type unchanged), but the reconciliation marker must stay ARMED so the next confirm
    /// gates through `getResult` instead of blindly submitting a new attempt against a live `R`.
    func test_requiresAction_actionHandlerFailed_keepsMarkerArmed_nextConfirmReconciles() async throws {
        let payment = MockPaymentService()
        payment.stubSession(makeSession())
        payment.stubSubmit([PaymentSnapshot(sessionId: "sess_1", status: .requiresAction, txnId: "txn_r")])
        payment.stubNextAction(.qrCode)
        let failErr = CheckoutError(code: "UNSUPPORTED_CAPABILITY", message: "x", category: .runtime, traceId: nil)
        let action = StubActionHandler(result: .failed(failErr))
        let store = PendingReconciliationStore()

        let controller = makeController(payment: payment, actionHandler: action, pendingStore: store)
        _ = try await controller.start(sessionId: "sess_1", customerAccessSecret: nil)

        let outcome = await controller.confirmSavedCard(paymentMethodId: "pm_1")

        if case .failed(let txnId, let err) = outcome {
            XCTAssertEqual(txnId, "txn_r")
            XCTAssertEqual(err.code, "UNSUPPORTED_CAPABILITY")
        } else {
            XCTFail("expected .failed, got \(outcome)")
        }
        XCTAssertTrue(store.isArmed("sess_1"), "a client-side action-handler failure must NOT disarm the marker")

        // Next confirm must gate: query getResult, not submit a fresh attempt.
        payment.stubGetResult([terminalSucceeded(txnId: "txn_r")])
        let second = await controller.confirmSavedCard(paymentMethodId: "pm_1")

        XCTAssertEqual(second, .succeeded(txnId: "txn_r"))
        XCTAssertEqual(payment.submitCallCount, 1, "the gated confirm must not submit again")
        XCTAssertEqual(payment.getResultCallCount, 1, "the gated confirm must query the server once")
    }

    // MARK: - Two-source single delivery dedup (leftover from Task 6 review, truly landed in Task 7)

    /// submit returns `.initial` (pending) → the controller polls to `.succeeded` via the poller.
    ///
    /// This replaces the trivial "two identical terminal snapshots delivered once" assertion from Task 6:
    /// there are now **two real result sources** (submit→pending, poll→terminal). It verifies the confirm
    /// resolves to a terminal state **exactly once** and that after resolution the **single active lock is
    /// released** (a subsequent confirm can start again) — the real two-source single-delivery check.
    func test_pendingThenPolledTerminal_deliversSingleOutcome() async throws {
        let payment = MockPaymentService()
        payment.stubSession(makeSession())
        // submit first returns non-terminal I; then getResult (polling) returns I, S in order.
        payment.stubSubmit([PaymentSnapshot(sessionId: "sess_1", status: .initial, txnId: "txn_p")])
        payment.stubGetResult([
            PaymentSnapshot(sessionId: "sess_1", status: .initial, txnId: "txn_p"),
            PaymentSnapshot(sessionId: "sess_1", status: .succeeded, txnId: "txn_done"),
        ])

        let controller = makeController(payment: payment, poller: noWaitPoller(payment: payment))
        _ = try await controller.start(sessionId: "sess_1", customerAccessSecret: nil)

        let outcome = await controller.confirmSavedCard(paymentMethodId: "pm_1")

        // Resolves to succeeded exactly once (the terminal state obtained from polling).
        if case .succeeded(let txnId) = outcome {
            XCTAssertEqual(txnId, "txn_done", "should deliver the terminal txnId obtained from polling")
        } else {
            XCTFail("pending→polled terminal should deliver succeeded once, got: \(outcome)")
        }
        XCTAssertEqual(payment.submitCallCount, 1, "one confirm submits only once")

        // The single active lock should be released after resolution: a subsequent confirm is not blocked by alreadyPresenting (can start again).
        payment.stubSubmit([terminalSucceeded()])
        let again = await controller.confirmSavedCard(paymentMethodId: "pm_2")
        if case .failed(_, let err) = again, err.code == "ALREADY_PRESENTING" {
            XCTFail("after a terminal resolution the single active lock should be released, so a subsequent confirm should be able to start")
        }
    }

    // MARK: - Invariant: reconcile first after pending / unknown, never blindly resubmit across attempts

    /// The three confirm paths, so every reconciliation assertion runs against each of them.
    private enum ConfirmPath: CaseIterable {
        case savedCard
        case newCard
        case wallet
    }

    private func confirm(_ path: ConfirmPath, on controller: CheckoutController) async -> CheckoutOutcome {
        switch path {
        case .savedCard:
            return await controller.confirmSavedCard(paymentMethodId: "pm_1")
        case .newCard:
            return await controller.confirmNewCard(newCardInput(), save: false, consent: nil)
        case .wallet:
            return await controller.confirmWallet(token: Data([0x01, 0x02]))
        }
    }

    /// Builds a started controller whose FIRST confirm resolves to `.unknown` (submit returns `I`, and
    /// the poller only ever sees `I`). Returns the payment mock with call counts already advanced.
    private func makeControllerAfterUnknown(
        path: ConfirmPath
    ) async throws -> (CheckoutController, MockPaymentService) {
        let rsaKey = try makeRSAPublicKey()
        let payment = MockPaymentService()
        payment.stubSession(makeSession(rsaPublicKey: rsaKey))
        let initial = PaymentSnapshot(sessionId: "sess_1", status: .initial, txnId: "txn_p")
        payment.stubSubmit([initial])
        payment.stubGetResult([initial])

        let controller = makeController(payment: payment, poller: noWaitPoller(payment: payment))
        _ = try await controller.start(sessionId: "sess_1", customerAccessSecret: nil)

        let first = await confirm(path, on: controller)
        guard case .unknown = first else {
            XCTFail("precondition: first confirm should resolve to unknown, got \(first) (\(path))")
            return (controller, payment)
        }
        XCTAssertEqual(payment.submitCallCount, 1, "precondition: one submit so far (\(path))")
        return (controller, payment)
    }

    /// (a) After `.unknown`, the next confirm does NOT submit again and DOES query `getResult`.
    func test_afterUnknown_nextConfirm_doesNotResubmit_andQueriesResult() async throws {
        for path in ConfirmPath.allCases {
            let (controller, payment) = try await makeControllerAfterUnknown(path: path)
            let getResultBefore = payment.getResultCallCount

            let second = await confirm(path, on: controller)

            XCTAssertEqual(payment.submitCallCount, 1, "must not submit again after unknown (\(path))")
            XCTAssertEqual(
                payment.getResultCallCount, getResultBefore + 1,
                "must reconcile with exactly one bounded getResult (\(path))")
            if case .unknown(let sessionId) = second {
                XCTAssertEqual(sessionId, "sess_1")
            } else {
                XCTFail("still non-terminal should resolve to unknown, got \(second) (\(path))")
            }
        }
    }

    /// (a, pending variant) A `.pending` outcome (requiresAction + handler pending) arms the same gate.
    func test_afterPending_nextConfirm_doesNotResubmit_andQueriesResult() async throws {
        let payment = MockPaymentService()
        payment.stubSession(makeSession())
        payment.stubSubmit([PaymentSnapshot(sessionId: "sess_1", status: .requiresAction, txnId: "txn_r")])
        payment.stubNextAction(.redirect(url: URL(string: "https://psp.example/redirect")!))
        payment.stubGetResult([PaymentSnapshot(sessionId: "sess_1", status: .requiresAction, txnId: "txn_r")])

        let controller = makeController(payment: payment, actionHandler: StubActionHandler(result: .pending))
        _ = try await controller.start(sessionId: "sess_1", customerAccessSecret: nil)

        let first = await controller.confirmSavedCard(paymentMethodId: "pm_1")
        guard case .pending = first else { return XCTFail("precondition: expected pending, got \(first)") }

        let second = await controller.confirmSavedCard(paymentMethodId: "pm_1")

        XCTAssertEqual(payment.submitCallCount, 1, "must not submit again after pending")
        XCTAssertEqual(payment.getResultCallCount, 1, "must reconcile with one getResult")
        if case .unknown = second {} else { XCTFail("requiresAction is non-terminal: expected unknown, got \(second)") }
    }

    /// (b) If reconciliation finds the earlier attempt actually succeeded, the confirm resolves
    /// `.succeeded` without a second submit, and the credential is cleared like any terminal path.
    func test_afterUnknown_reconciliationSucceeded_resolvesSucceeded_noSecondSubmit() async throws {
        for path in ConfirmPath.allCases {
            let (controller, payment) = try await makeControllerAfterUnknown(path: path)
            payment.stubGetResult([terminalSucceeded(txnId: "txn_late")])

            let second = await confirm(path, on: controller)

            XCTAssertEqual(second, .succeeded(txnId: "txn_late"), "(\(path))")
            XCTAssertEqual(payment.submitCallCount, 1, "no second submit when the first actually succeeded (\(path))")
        }
    }

    func test_afterUnknown_reconciliationSucceeded_clearsCredential() async throws {
        let payment = MockPaymentService()
        payment.stubSession(makeSession())
        let initial = PaymentSnapshot(sessionId: "sess_1", status: .initial, txnId: nil)
        payment.stubSubmit([initial])
        payment.stubGetResult([initial])
        let credentials = CredentialStore()
        let controller = makeController(
            payment: payment, credentials: credentials, poller: noWaitPoller(payment: payment))
        _ = try await controller.start(sessionId: "sess_1", customerAccessSecret: nil)
        _ = await controller.confirmSavedCard(paymentMethodId: "pm_1")

        await credentials.hold(customerAccessSecret: "secret_abc")
        payment.stubGetResult([terminalSucceeded()])
        _ = await controller.confirmSavedCard(paymentMethodId: "pm_1")

        let held = await credentials.current()
        XCTAssertNil(held, "reconciled success is terminal: credential must be cleared")
    }

    /// (c) Reconciliation finds a terminal failure: the confirm reports `.failed` (no submit), the flag
    /// clears, and the NEXT confirm is a genuine fresh attempt with a NEW attemptId.
    func test_afterUnknown_reconciliationFailed_reportsFailed_thenNextConfirmIsFreshAttempt() async throws {
        for path in ConfirmPath.allCases {
            let (controller, payment) = try await makeControllerAfterUnknown(path: path)
            let firstAttemptId = try XCTUnwrap(payment.lastSubmitRequest?.attemptId)
            let getResultBefore = payment.getResultCallCount
            payment.stubGetResult([PaymentSnapshot(sessionId: "sess_1", status: .failed, txnId: "txn_f")])

            let second = await confirm(path, on: controller)

            if case .failed(let txnId, let error) = second {
                XCTAssertEqual(txnId, "txn_f")
                XCTAssertEqual(error.code, "PAYMENT_FAILED")
            } else {
                XCTFail("confirmed failure should resolve to failed, got \(second) (\(path))")
            }
            XCTAssertEqual(payment.submitCallCount, 1, "the reconciling call itself must not submit (\(path))")
            XCTAssertEqual(payment.getResultCallCount, getResultBefore + 1, "one gate query (\(path))")

            // Third call: flag cleared -> normal fresh attempt.
            payment.stubSubmit([terminalSucceeded(txnId: "txn_new")])
            let third = await confirm(path, on: controller)

            XCTAssertEqual(payment.submitCallCount, 2, "a fresh attempt submits normally (\(path))")
            XCTAssertEqual(third, .succeeded(txnId: "txn_new"), "(\(path))")
            XCTAssertNotEqual(
                payment.lastSubmitRequest?.attemptId, firstAttemptId,
                "the fresh attempt mints a NEW attemptId (\(path))")
        }
    }

    /// (d) Still non-terminal: resolves `.unknown` again, never submits, and the flag stays set for a
    /// subsequent call (which can then reconcile to a terminal state).
    func test_afterUnknown_stillNonTerminal_staysGated_untilTerminalSeen() async throws {
        for path in ConfirmPath.allCases {
            let (controller, payment) = try await makeControllerAfterUnknown(path: path)

            let second = await confirm(path, on: controller)
            let third = await confirm(path, on: controller)

            for outcome in [second, third] {
                if case .unknown = outcome {} else { XCTFail("expected unknown, got \(outcome) (\(path))") }
            }
            XCTAssertEqual(payment.submitCallCount, 1, "gate must hold across repeated calls (\(path))")

            payment.stubGetResult([terminalSucceeded(txnId: "txn_eventual")])
            let fourth = await confirm(path, on: controller)
            XCTAssertEqual(fourth, .succeeded(txnId: "txn_eventual"), "(\(path))")
            XCTAssertEqual(payment.submitCallCount, 1, "(\(path))")
        }
    }

    /// (d, query failure) If the reconciliation query itself throws, the outcome is `.unknown` and the
    /// gate stays armed (no submit).
    func test_afterUnknown_reconciliationQueryThrows_staysUnknown_noSubmit() async throws {
        for path in ConfirmPath.allCases {
            let (controller, payment) = try await makeControllerAfterUnknown(path: path)
            payment.stubGetResultError(URLError(.notConnectedToInternet))
            let getResultBefore = payment.getResultCallCount

            let second = await confirm(path, on: controller)

            XCTAssertEqual(payment.getResultCallCount, getResultBefore + 1, "the gate did query (\(path))")
            if case .unknown(let sessionId) = second {
                XCTAssertEqual(sessionId, "sess_1")
            } else {
                XCTFail("failed reconciliation query should resolve to unknown, got \(second) (\(path))")
            }
            XCTAssertEqual(payment.submitCallCount, 1, "(\(path))")
        }
    }

    /// A second confirm arriving while the gate's `getResult` is in flight is rejected with
    /// `alreadyPresenting` and does not submit (the gate holds the active lock).
    func test_confirmDuringGateQuery_isRejectedAlreadyPresenting_andDoesNotSubmit() async throws {
        let (controller, payment) = try await makeControllerAfterUnknown(path: .savedCard)
        payment.stubGetResultDelay(.milliseconds(300)) // keep the gate's query in flight
        let getResultBefore = payment.getResultCallCount

        async let gated = controller.confirmSavedCard(paymentMethodId: "pm_1")
        try await Task.sleep(nanoseconds: 100_000_000) // let the gate start its query
        let concurrent = await controller.confirmSavedCard(paymentMethodId: "pm_1")
        let gatedOutcome = await gated

        if case .failed(_, let error) = concurrent {
            XCTAssertEqual(error.code, "ALREADY_PRESENTING")
        } else {
            XCTFail("concurrent confirm during the gate should be rejected, got \(concurrent)")
        }
        if case .unknown = gatedOutcome {} else { XCTFail("gate should still resolve unknown, got \(gatedOutcome)") }
        XCTAssertEqual(payment.submitCallCount, 1, "neither call may submit")
        XCTAssertEqual(payment.getResultCallCount, getResultBefore + 1, "only the gated call queried")
    }

    /// The gate's `.unknown` (still non-terminal) leaves the credential UNTOUCHED, unlike the
    /// submit-then-query-fail path (which clears it): the user may still be mid-flow in the sheet.
    func test_gateUnknown_leavesCredentialUntouched_whereasSubmitThenQueryFailClearsIt() async throws {
        // Gate path: pending marker armed via an `.initial` poll that ends unknown (clears credential),
        // THEN the credential is re-held, and the gate's still-non-terminal query must not clear it.
        let payment = MockPaymentService()
        payment.stubSession(makeSession())
        let initial = PaymentSnapshot(sessionId: "sess_1", status: .initial, txnId: nil)
        payment.stubSubmit([initial])
        payment.stubGetResult([initial])
        let credentials = CredentialStore()
        let controller = makeController(
            payment: payment, credentials: credentials, poller: noWaitPoller(payment: payment))
        _ = try await controller.start(sessionId: "sess_1", customerAccessSecret: nil)
        _ = await controller.confirmSavedCard(paymentMethodId: "pm_1")

        await credentials.hold(customerAccessSecret: "secret_keep")
        let gated = await controller.confirmSavedCard(paymentMethodId: "pm_1")
        if case .unknown = gated {} else { XCTFail("precondition: gate should resolve unknown, got \(gated)") }
        let heldAfterGate = await credentials.current()
        XCTAssertEqual(heldAfterGate, "secret_keep", "the gate's non-terminal result must not clear the credential")

        // Contrast: submit throws AND the follow-up query throws -> unknown, credential cleared.
        let payment2 = MockPaymentService()
        payment2.stubSession(makeSession())
        payment2.stubSubmitError(URLError(.timedOut))
        payment2.stubGetResultError(URLError(.notConnectedToInternet))
        let credentials2 = CredentialStore()
        let controller2 = makeController(payment: payment2, credentials: credentials2)
        _ = try await controller2.start(sessionId: "sess_1", customerAccessSecret: "secret_gone")
        _ = await controller2.confirmSavedCard(paymentMethodId: "pm_1")
        let heldAfterSubmitFail = await credentials2.current()
        XCTAssertNil(heldAfterSubmitFail, "the submit-then-query-fail path clears the credential")
    }

    /// A confirm that resolved to a TERMINAL outcome never arms the gate: the next confirm submits.
    func test_afterTerminalFailure_nextConfirmSubmitsWithoutReconciling() async throws {
        let payment = MockPaymentService()
        payment.stubSession(makeSession())
        payment.stubSubmit([PaymentSnapshot(sessionId: "sess_1", status: .failed, txnId: "t1")])
        let controller = makeController(payment: payment)
        _ = try await controller.start(sessionId: "sess_1", customerAccessSecret: nil)

        _ = await controller.confirmSavedCard(paymentMethodId: "pm_1")
        payment.stubSubmit([terminalSucceeded()])
        _ = await controller.confirmSavedCard(paymentMethodId: "pm_1")

        XCTAssertEqual(payment.submitCallCount, 2)
        XCTAssertEqual(payment.getResultCallCount, 0, "no reconciliation after a terminal outcome")
    }

    // MARK: - reconcile(sessionId:) — bounded query-only poll, used by the UI reconciliation phase

    /// `reconcile` resolves a terminal `S` to `.succeeded`, clears the marker, never calls submit.
    func test_reconcile_terminalSucceeded_resolvesSucceeded_clearsMarker_noSubmit() async throws {
        let payment = MockPaymentService()
        payment.stubSession(makeSession())
        let initial = PaymentSnapshot(sessionId: "sess_1", status: .initial, txnId: nil)
        payment.stubSubmit([initial])
        payment.stubGetResult([initial])
        let store = PendingReconciliationStore()
        let controller = makeController(
            payment: payment, poller: noWaitPoller(payment: payment), pendingStore: store)
        _ = try await controller.start(sessionId: "sess_1", customerAccessSecret: nil)
        _ = await controller.confirmSavedCard(paymentMethodId: "pm_1")
        XCTAssertTrue(store.isArmed("sess_1"), "precondition: marker armed after unknown")

        payment.stubGetResult([terminalSucceeded(txnId: "txn_r")])
        let outcome = await controller.reconcile(sessionId: "sess_1")

        XCTAssertEqual(outcome, .succeeded(txnId: "txn_r"))
        XCTAssertFalse(store.isArmed("sess_1"))
        XCTAssertEqual(payment.submitCallCount, 1, "reconcile must never submit")
    }

    /// `reconcile` resolves a terminal `F` to `.failed`, clears the marker, never calls submit.
    func test_reconcile_terminalFailed_resolvesFailed_clearsMarker_noSubmit() async throws {
        let payment = MockPaymentService()
        payment.stubSession(makeSession())
        let initial = PaymentSnapshot(sessionId: "sess_1", status: .initial, txnId: nil)
        payment.stubSubmit([initial])
        payment.stubGetResult([initial])
        let store = PendingReconciliationStore()
        let controller = makeController(
            payment: payment, poller: noWaitPoller(payment: payment), pendingStore: store)
        _ = try await controller.start(sessionId: "sess_1", customerAccessSecret: nil)
        _ = await controller.confirmSavedCard(paymentMethodId: "pm_1")

        payment.stubGetResult([PaymentSnapshot(sessionId: "sess_1", status: .failed, txnId: "txn_f")])
        let outcome = await controller.reconcile(sessionId: "sess_1")

        if case .failed(let txnId, let error) = outcome {
            XCTAssertEqual(txnId, "txn_f")
            XCTAssertEqual(error.code, "PAYMENT_FAILED")
        } else {
            XCTFail("expected failed, got \(outcome)")
        }
        XCTAssertFalse(store.isArmed("sess_1"))
        XCTAssertEqual(payment.submitCallCount, 1, "reconcile must never submit")
    }

    /// Still non-terminal when the poll limit is reached, or the query keeps throwing: `.unknown`, marker stays.
    func test_reconcile_stillNonTerminalOrThrowing_resolvesUnknown_keepsMarker_noSubmit() async throws {
        for throwing in [false, true] {
            let payment = MockPaymentService()
            payment.stubSession(makeSession())
            let initial = PaymentSnapshot(sessionId: "sess_1", status: .initial, txnId: nil)
            payment.stubSubmit([initial])
            payment.stubGetResult([initial])
            let store = PendingReconciliationStore()
            let controller = makeController(
                payment: payment, poller: noWaitPoller(payment: payment), pendingStore: store)
            _ = try await controller.start(sessionId: "sess_1", customerAccessSecret: nil)
            _ = await controller.confirmSavedCard(paymentMethodId: "pm_1")

            if throwing {
                payment.stubGetResultError(URLError(.notConnectedToInternet))
            } else {
                payment.stubGetResult([initial])
            }
            let outcome = await controller.reconcile(sessionId: "sess_1")

            if case .unknown(let sessionId) = outcome {
                XCTAssertEqual(sessionId, "sess_1")
            } else {
                XCTFail("expected unknown (throwing=\(throwing)), got \(outcome)")
            }
            XCTAssertTrue(store.isArmed("sess_1"), "marker must stay armed (throwing=\(throwing))")
            XCTAssertEqual(payment.submitCallCount, 1, "reconcile must never submit (throwing=\(throwing))")
        }
    }

    /// Cancelling the reconcile task returns promptly instead of running out the full bounded poll:
    /// inject a sleep seam that signals once it has been entered, then cancel and assert the call
    /// returns quickly with the latest (non-terminal) snapshot mapped to `.unknown`.
    func test_reconcile_cancellation_returnsPromptly() async throws {
        let payment = MockPaymentService()
        payment.stubSession(makeSession())
        let initial = PaymentSnapshot(sessionId: "sess_1", status: .initial, txnId: nil)
        payment.stubGetResult([initial])
        // Arm the marker directly. Driving a first confirm here would route its `.initial` submit
        // result through this same never-cancelled, 60s-sleeping poller and hang the test.
        let store = PendingReconciliationStore()
        store.arm("sess_1")

        let enteredSleep = XCTestExpectation(description: "poller entered its sleep")
        let poller = ResultPoller(
            service: payment,
            config: PollConfig(initial: 1, max: 1, overallLimit: 90),
            sleep: { _ in
                enteredSleep.fulfill()
                // Sleep "forever" relative to the test; cancellation must interrupt this promptly.
                try await Task.sleep(nanoseconds: 60 * 1_000_000_000)
            }
        )
        let controller = makeController(payment: payment, poller: poller, pendingStore: store)
        _ = try await controller.start(sessionId: "sess_1", customerAccessSecret: nil)

        let task = Task { await controller.reconcile(sessionId: "sess_1") }
        await fulfillment(of: [enteredSleep], timeout: 5)
        task.cancel()

        let start = Date()
        let outcome = await task.value
        XCTAssertLessThan(
            Date().timeIntervalSince(start), 2,
            "cancellation must return promptly, not after the full backoff/limit")
        if case .unknown = outcome {} else { XCTFail("expected unknown, got \(outcome)") }
        XCTAssertTrue(store.isArmed("sess_1"), "a cancelled reconcile must leave the marker set")
        XCTAssertEqual(payment.submitCallCount, 0, "reconcile is query-only")
        // A cancelled `Task.sleep` throws immediately, so a poller that ignored cancellation would
        // still "return quickly" — but only after spinning through the whole ladder of queries.
        XCTAssertEqual(payment.getResultCallCount, 1, "cancellation must stop polling, not burn the backoff ladder")
    }

    // MARK: - Shared PendingReconciliationStore (F3): markers survive across controllers / are session-scoped

    /// A second controller built from the SAME store honors the first controller's marker: it
    /// reconciles instead of submitting for the same session.
    func test_sharedStore_secondControllerHonorsFirstControllersMarker() async throws {
        let payment = MockPaymentService()
        payment.stubSession(makeSession())
        let initial = PaymentSnapshot(sessionId: "sess_1", status: .initial, txnId: nil)
        payment.stubSubmit([initial])
        payment.stubGetResult([initial])
        let store = PendingReconciliationStore()

        let first = makeController(payment: payment, poller: noWaitPoller(payment: payment), pendingStore: store)
        _ = try await first.start(sessionId: "sess_1", customerAccessSecret: nil)
        _ = await first.confirmSavedCard(paymentMethodId: "pm_1")
        XCTAssertTrue(store.isArmed("sess_1"))

        // A brand new controller instance, same store, same session: must reconcile, not resubmit.
        let second = makeController(payment: payment, poller: noWaitPoller(payment: payment), pendingStore: store)
        _ = try await second.start(sessionId: "sess_1", customerAccessSecret: nil)
        payment.stubGetResult([terminalSucceeded(txnId: "txn_shared")])

        let outcome = await second.confirmSavedCard(paymentMethodId: "pm_1")

        XCTAssertEqual(outcome, .succeeded(txnId: "txn_shared"))
        XCTAssertEqual(payment.submitCallCount, 1, "the second controller must not have submitted again")
    }

    /// A controller built with a DIFFERENT store does not see the marker: it submits normally.
    func test_differentStore_doesNotHonorMarker() async throws {
        let payment = MockPaymentService()
        payment.stubSession(makeSession())
        let initial = PaymentSnapshot(sessionId: "sess_1", status: .initial, txnId: nil)
        payment.stubSubmit([initial])
        payment.stubGetResult([initial])

        let first = makeController(
            payment: payment, poller: noWaitPoller(payment: payment), pendingStore: PendingReconciliationStore())
        _ = try await first.start(sessionId: "sess_1", customerAccessSecret: nil)
        _ = await first.confirmSavedCard(paymentMethodId: "pm_1")

        let second = makeController(
            payment: payment, poller: noWaitPoller(payment: payment), pendingStore: PendingReconciliationStore())
        _ = try await second.start(sessionId: "sess_1", customerAccessSecret: nil)
        payment.stubSubmit([terminalSucceeded(txnId: "txn_fresh")])

        let outcome = await second.confirmSavedCard(paymentMethodId: "pm_1")

        XCTAssertEqual(outcome, .succeeded(txnId: "txn_fresh"))
        XCTAssertEqual(payment.submitCallCount, 2, "a different store must submit a fresh attempt")
    }

    /// A marker for session A does not gate session B, even on the shared store.
    func test_sharedStore_sessionAMarker_doesNotGateSessionB() async throws {
        let store = PendingReconciliationStore()
        store.arm("sess_A")

        let payment = MockPaymentService()
        payment.stubSession(makeSession(id: "sess_B"))
        payment.stubSubmit([terminalSucceeded(sessionId: "sess_B", txnId: "txn_b")])
        let controller = makeController(payment: payment, pendingStore: store)
        _ = try await controller.start(sessionId: "sess_B", customerAccessSecret: nil)

        let outcome = await controller.confirmSavedCard(paymentMethodId: "pm_1")

        XCTAssertEqual(outcome, .succeeded(txnId: "txn_b"))
        XCTAssertEqual(payment.submitCallCount, 1, "session B must submit normally; A's marker must not gate it")
        XCTAssertEqual(payment.getResultCallCount, 0, "no reconciliation query for an unrelated session")
    }

    // MARK: - dismiss cleanup

    /// `reconcile` must not clear a marker that was RE-ARMED (by a concurrent confirm from another
    /// controller sharing the store) while its `getResult` was in flight: its terminal verdict may
    /// belong to the older attempt.
    func test_reconcile_doesNotDisarmMarkerRearmedDuringQuery() async throws {
        let payment = MockPaymentService()
        payment.stubSession(makeSession())
        payment.stubGetResult([PaymentSnapshot(sessionId: "sess_1", status: .failed, txnId: "txn_old")])
        payment.stubGetResultDelay(.milliseconds(150))
        let store = PendingReconciliationStore()
        store.arm("sess_1")
        let controller = makeController(
            payment: payment, poller: noWaitPoller(payment: payment), pendingStore: store)
        _ = try await controller.start(sessionId: "sess_1", customerAccessSecret: nil)

        let task = Task { await controller.reconcile(sessionId: "sess_1") }
        try await Task.sleep(nanoseconds: 40_000_000)   // let the query start
        store.arm("sess_1")                             // a newer attempt re-arms meanwhile
        let outcome = await task.value

        if case .failed = outcome {} else { XCTFail("the verdict itself is still reported, got \(outcome)") }
        XCTAssertTrue(store.isArmed("sess_1"), "a marker re-armed during the query must survive the older verdict")
    }

    /// Same protection on the confirm-time gate path.
    func test_gate_doesNotDisarmMarkerRearmedDuringQuery() async throws {
        let payment = MockPaymentService()
        payment.stubSession(makeSession())
        payment.stubGetResult([PaymentSnapshot(sessionId: "sess_1", status: .failed, txnId: "txn_old")])
        payment.stubGetResultDelay(.milliseconds(150))
        let store = PendingReconciliationStore()
        store.arm("sess_1")
        let controller = makeController(payment: payment, pendingStore: store)
        _ = try await controller.start(sessionId: "sess_1", customerAccessSecret: nil)

        let task = Task { await controller.confirmSavedCard(paymentMethodId: "pm_1") }
        try await Task.sleep(nanoseconds: 40_000_000)
        store.arm("sess_1")
        _ = await task.value

        XCTAssertTrue(store.isArmed("sess_1"), "gate must not clear a marker re-armed during its query")
        XCTAssertEqual(payment.submitCallCount, 0)
    }

    // MARK: - Store semantics / sharing (item 7)

    /// `disarm(_:ifGeneration:)` clears only when no `arm` happened since the generation was read.
    func test_store_conditionalDisarm_respectsGeneration() {
        let store = PendingReconciliationStore()
        store.arm("s")
        let g = store.generation("s")
        store.arm("s")
        store.disarm("s", ifGeneration: g)
        XCTAssertTrue(store.isArmed("s"), "stale generation must not disarm")
        store.disarm("s", ifGeneration: store.generation("s"))
        XCTAssertFalse(store.isArmed("s"), "current generation disarms")
    }

    /// `dismiss()` is not a terminal resolution: the marker stays armed, so the next confirm on the
    /// same controller/session still gates (query first).
    func test_dismiss_leavesMarkerArmed_nextConfirmGates() async throws {
        let payment = MockPaymentService()
        payment.stubSession(makeSession())
        let initial = PaymentSnapshot(sessionId: "sess_1", status: .initial, txnId: nil)
        payment.stubSubmit([initial])
        payment.stubGetResult([initial])
        let store = PendingReconciliationStore()
        let controller = makeController(
            payment: payment, poller: noWaitPoller(payment: payment), pendingStore: store)
        _ = try await controller.start(sessionId: "sess_1", customerAccessSecret: nil)
        _ = await controller.confirmSavedCard(paymentMethodId: "pm_1")
        XCTAssertTrue(store.isArmed("sess_1"))

        await controller.dismiss()
        XCTAssertTrue(store.isArmed("sess_1"), "dismiss must not clear the marker")

        _ = try await controller.start(sessionId: "sess_1", customerAccessSecret: nil)
        let before = payment.getResultCallCount
        let outcome = await controller.confirmSavedCard(paymentMethodId: "pm_1")
        if case .unknown = outcome {} else { XCTFail("expected gated .unknown, got \(outcome)") }
        XCTAssertEqual(payment.submitCallCount, 1, "no resubmit after dismiss")
        XCTAssertGreaterThan(payment.getResultCallCount, before, "gate queried the server")
    }

    /// Controllers from the same `SunbayCheckout.makeController` share the marker store: one's
    /// unknown gates the other's confirm.
    func test_sunbayCheckout_makeController_sharesStore_acrossControllers() async throws {
        let payment = MockPaymentService()
        payment.stubSession(makeSession())
        // `R` + a `.pending` action handler arms the marker without involving the (real-sleeping) default poller.
        let requiresAction = PaymentSnapshot(sessionId: "sess_1", status: .requiresAction, txnId: "txn_r")
        payment.stubSubmit([requiresAction])
        payment.stubGetResult([requiresAction])
        payment.stubNextAction(.redirect(url: URL(string: "https://psp.example/redirect")!))
        let checkout = SunbayCheckout(
            configuration: CheckoutConfiguration(environment: .test),
            paymentService: payment, cofService: MockCofService())
        let first = checkout.makeController(
            credentials: CredentialStore(), actionHandler: StubActionHandler(result: .pending))
        let second = checkout.makeController(
            credentials: CredentialStore(), actionHandler: StubActionHandler(result: .pending))
        _ = try await first.start(sessionId: "sess_1", customerAccessSecret: nil)
        let firstOutcome = await first.confirmSavedCard(paymentMethodId: "pm_1")
        XCTAssertEqual(firstOutcome, .pending(txnId: "txn_r"))
        _ = try await second.start(sessionId: "sess_1", customerAccessSecret: nil)

        let outcome = await second.confirmSavedCard(paymentMethodId: "pm_1")

        XCTAssertEqual(outcome, .unknown(sessionId: "sess_1"), "gated: still R after the query")
        XCTAssertEqual(payment.submitCallCount, 1, "the second controller must reconcile, not submit")
        XCTAssertEqual(payment.getResultCallCount, 1)
    }

    // MARK: - dismiss cleanup (credentials)

    func test_dismiss_clearsCredentials() async throws {
        let payment = MockPaymentService()
        payment.stubSession(makeSession())
        let credentials = CredentialStore()

        let controller = makeController(payment: payment, credentials: credentials)
        _ = try await controller.start(sessionId: "sess_1", customerAccessSecret: "secret_abc")
        await credentials.hold(customerAccessSecret: "secret_abc")

        await controller.dismiss()

        let held = await credentials.current()
        XCTAssertNil(held, "dismiss should clear credentials")
    }
}
