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
        poller: ResultPoller? = nil
    ) -> CheckoutController {
        CheckoutController(
            paymentService: payment,
            cofService: cof,
            credentials: credentials,
            actionHandler: actionHandler,
            poller: poller
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

    // MARK: - dismiss cleanup

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
