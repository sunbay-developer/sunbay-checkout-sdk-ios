import Foundation
import Security
import XCTest

@testable import SunbayCheckout

/// Orchestration / invariant tests for `CheckoutController`.
///
/// Covers the realigned submit contract (see
/// `docs/superpowers/specs/2026-11-06-submit-lock-and-no-poll-realignment-design.md`):
/// - single active session (one confirm at a time); the lock covers only the in-flight submit;
/// - one `attemptId` per confirm; query ONCE on submit failure, never blindly resubmit;
/// - a non-terminal `I` submit result maps straight to `.pending` (the SDK does NOT client-poll);
/// - `R` (requiresAction) delegates to `ActionHandling`;
/// - credentials cleared on a terminal state;
/// - the submit-field differences across the three paths.
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
        actionHandler: StubActionHandler = StubActionHandler()
    ) -> CheckoutController {
        CheckoutController(
            paymentService: payment,
            cofService: cof,
            credentials: credentials,
            actionHandler: actionHandler
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

    /// After a confirm resolves, the single-active lock is released so the next confirm can start.
    func test_lockReleased_afterResolution_nextConfirmNotBlocked() async throws {
        let payment = MockPaymentService()
        payment.stubSession(makeSession())
        payment.stubSubmit([terminalSucceeded()])

        let controller = makeController(payment: payment)
        _ = try await controller.start(sessionId: "sess_1", customerAccessSecret: nil)

        _ = await controller.confirmSavedCard(paymentMethodId: "pm_1")

        payment.stubSubmit([terminalSucceeded(txnId: "txn_2")])
        let again = await controller.confirmSavedCard(paymentMethodId: "pm_1")
        if case .failed(_, let err) = again, err.code == "ALREADY_PRESENTING" {
            XCTFail("the active lock should be released after a resolution")
        }
    }

    // MARK: - Invariant: query once on submit failure, never blindly resubmit

    func test_submitTimeout_queriesResultOnce_neverResubmits() async throws {
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

    // MARK: - Non-terminal submit result (I) → pending, no client polling

    /// The core realignment: a submit that returns a non-terminal `I` maps STRAIGHT to `.pending`.
    /// The SDK does not poll (`getResult` is never called), so the lock is released immediately and
    /// the host reconciles later via `retrievePayment`.
    func test_submitInitial_mapsToPending_withoutPolling() async throws {
        let payment = MockPaymentService()
        payment.stubSession(makeSession())
        payment.stubSubmit([PaymentSnapshot(sessionId: "sess_1", status: .initial, txnId: "txn_p")])

        let controller = makeController(payment: payment)
        _ = try await controller.start(sessionId: "sess_1", customerAccessSecret: nil)

        let outcome = await controller.confirmSavedCard(paymentMethodId: "pm_1")

        if case .pending(let txnId) = outcome {
            XCTAssertEqual(txnId, "txn_p", "pending should carry the submit snapshot's txnId")
        } else {
            XCTFail("a non-terminal I submit result should map to pending, got: \(outcome)")
        }
        XCTAssertEqual(payment.submitCallCount, 1)
        XCTAssertEqual(payment.getResultCallCount, 0, "the SDK must NOT poll for the result")
    }

    /// After an `I → pending`, the next confirm is a normal fresh attempt (a NEW attemptId, a new
    /// submit): there is no cross-attempt gate holding it back. Duplicate protection is the backend's
    /// job via attemptId/txnId, not a frozen UI.
    func test_afterPending_nextConfirmIsFreshSubmit() async throws {
        let payment = MockPaymentService()
        payment.stubSession(makeSession())
        payment.stubSubmit([PaymentSnapshot(sessionId: "sess_1", status: .initial, txnId: "txn_p")])

        let controller = makeController(payment: payment)
        _ = try await controller.start(sessionId: "sess_1", customerAccessSecret: nil)

        let first = await controller.confirmSavedCard(paymentMethodId: "pm_1")
        guard case .pending = first else { return XCTFail("precondition: expected pending, got \(first)") }
        let firstAttemptId = try XCTUnwrap(payment.lastSubmitRequest?.attemptId)

        payment.stubSubmit([terminalSucceeded(txnId: "txn_new")])
        let second = await controller.confirmSavedCard(paymentMethodId: "pm_1")

        XCTAssertEqual(second, .succeeded(txnId: "txn_new"))
        XCTAssertEqual(payment.submitCallCount, 2, "the next confirm submits a fresh attempt")
        XCTAssertEqual(payment.getResultCallCount, 0, "no reconciliation query gates the next confirm")
        XCTAssertNotEqual(
            payment.lastSubmitRequest?.attemptId, firstAttemptId, "a fresh attempt mints a new attemptId")
    }

    // MARK: - New card: encrypt and submit

    func test_newCard_encryptsAndSubmits() async throws {
        let rsaKey = try makeRSAPublicKey()
        let payment = MockPaymentService()
        payment.stubSession(makeSession(rsaPublicKey: rsaKey))
        payment.stubSubmit([terminalSucceeded()])

        let controller = makeController(payment: payment)
        _ = try await controller.start(sessionId: "sess_1", customerAccessSecret: nil)

        _ = await controller.confirmNewCard(newCardInput(), save: false)

        let req = try XCTUnwrap(payment.lastSubmitRequest)
        XCTAssertNotNil(req.cardEncryptedData)
        XCTAssertFalse(req.cardEncryptedData?.isEmpty ?? true, "a new card should carry non-empty ciphertext")
        XCTAssertNil(req.savedCardId, "a new card must not carry savedCardId")
        XCTAssertNil(req.walletToken)
    }

    // MARK: - Saved card: carry only paymentMethodId, no card data

    func test_savedCard_submitsSavedCardId_noCardData() async throws {
        let payment = MockPaymentService()
        payment.stubSession(makeSession())
        payment.stubSubmit([terminalSucceeded()])

        let controller = makeController(payment: payment)
        _ = try await controller.start(sessionId: "sess_1", customerAccessSecret: nil)

        _ = await controller.confirmSavedCard(paymentMethodId: "pm_42")

        let req = try XCTUnwrap(payment.lastSubmitRequest)
        XCTAssertEqual(req.savedCardId, "pm_42")
        XCTAssertEqual(req.paymentMethod, "TOKEN")
        XCTAssertNil(req.cardEncryptedData, "a saved card must not carry card ciphertext")
        XCTAssertNil(req.walletToken)
    }


    // MARK: - Real submit contract (Task 4)

    func test_newCard_saveTrue_cofDisabled_storeCardNil() async throws {
        let payment = MockPaymentService()
        payment.stubSession(makeSession(cofEnabled: false, rsaPublicKey: try makeRSAPublicKey()))
        payment.stubSubmit([terminalSucceeded()])
        let controller = makeController(payment: payment)
        _ = try await controller.start(sessionId: "sess_1", customerAccessSecret: nil)

        _ = await controller.confirmNewCard(newCardInput(), save: true)

        XCTAssertNil(payment.lastSubmitRequest?.storeCard)
    }

    func test_newCard_saveTrue_cofEnabled_storeCardTrue() async throws {
        let payment = MockPaymentService()
        payment.stubSession(makeSession(cofEnabled: true, rsaPublicKey: try makeRSAPublicKey()))
        payment.stubSubmit([terminalSucceeded()])
        let controller = makeController(payment: payment)
        _ = try await controller.start(sessionId: "sess_1", customerAccessSecret: nil)

        _ = await controller.confirmNewCard(newCardInput(), save: true)

        XCTAssertEqual(payment.lastSubmitRequest?.storeCard, true)
    }

    func test_newCard_saveFalse_cofEnabled_storeCardNil() async throws {
        let payment = MockPaymentService()
        payment.stubSession(makeSession(cofEnabled: true, rsaPublicKey: try makeRSAPublicKey()))
        payment.stubSubmit([terminalSucceeded()])
        let controller = makeController(payment: payment)
        _ = try await controller.start(sessionId: "sess_1", customerAccessSecret: nil)

        _ = await controller.confirmNewCard(newCardInput(), save: false)

        XCTAssertNil(payment.lastSubmitRequest?.storeCard)
    }

    func test_submit_carriesCheckoutClientSecret_andSavedCardCredentials() async throws {
        let payment = MockPaymentService()
        payment.stubSession(makeSession())
        payment.stubSubmit([terminalSucceeded()])
        let controller = makeController(payment: payment)
        _ = try await controller.start(
            sessionId: "sess_1", customerAccessSecret: "cas_1", checkoutClientSecret: "ccs_1")

        _ = await controller.confirmSavedCard(paymentMethodId: "pm_7")

        let req = try XCTUnwrap(payment.lastSubmitRequest)
        XCTAssertEqual(req.checkoutClientSecret, "ccs_1")
        XCTAssertEqual(req.paymentMethod, "TOKEN")
        XCTAssertEqual(req.savedCardId, "pm_7")
        XCTAssertEqual(req.customerAccessSecret, "cas_1")
    }

    func test_submit_thrownNonNetworkCheckoutError_failsWithoutResultQuery() async throws {
        let payment = MockPaymentService()
        payment.stubSession(makeSession())
        payment.stubSubmitError(
            CheckoutError(code: "PAYMENT_METHOD_NOT_ALLOWED", message: "x", category: .payment, traceId: nil))
        let controller = makeController(payment: payment)
        _ = try await controller.start(sessionId: "sess_1", customerAccessSecret: nil)

        let outcome = await controller.confirmSavedCard(paymentMethodId: "pm_1")

        guard case .failed(let txnId, let err) = outcome else { return XCTFail("expected failed, got \(outcome)") }
        XCTAssertNil(txnId)
        XCTAssertEqual(err.code, "PAYMENT_METHOD_NOT_ALLOWED")
        XCTAssertEqual(payment.getResultCallCount, 0)
    }

    func test_submit_thrownURLError_queriesOnceThenUnknown() async throws {
        let payment = MockPaymentService()
        payment.stubSession(makeSession())
        payment.stubSubmitError(URLError(.timedOut))
        payment.stubGetResultError(URLError(.timedOut))
        let controller = makeController(payment: payment)
        _ = try await controller.start(sessionId: "sess_1", customerAccessSecret: nil)

        let outcome = await controller.confirmSavedCard(paymentMethodId: "pm_1")

        guard case .unknown = outcome else { return XCTFail("expected unknown, got \(outcome)") }
        XCTAssertEqual(payment.getResultCallCount, 1)
    }

    func test_submitRequest_allStringForms_hideSecrets() {
        let token = Data("WALLETTOKEN".utf8)
        let req = SubmitRequest(
            sessionId: "sess_1", paymentMethod: "CARD", attemptId: UUID(),
            cardEncryptedData: "CIPHER", walletToken: token, savedCardId: "pm_1",
            customerAccessSecret: "cas_x", checkoutClientSecret: "ccs_x")
        var dumped = ""
        dump(req, to: &dumped)
        let forms = [
            "reflecting": String(reflecting: req),
            "interpolation": "\(req)",
            "describing": String(describing: req),
            "dump": dumped,
        ]
        let secrets = [
            "CIPHER", "ccs_x", "cas_x", "WALLETTOKEN",
            token.base64EncodedString(), String(describing: token),
        ]
        for (name, text) in forms {
            for secret in secrets {
                XCTAssertFalse(text.contains(secret), "\(name) leaked \(secret)")
            }
        }
    }

    // MARK: - Wallet: carry only walletToken

    func test_wallet_submitsWalletToken_noCardData() async throws {
        let payment = MockPaymentService()
        payment.stubSession(makeSession())
        payment.stubSubmit([terminalSucceeded()])

        let controller = makeController(payment: payment)
        _ = try await controller.start(sessionId: "sess_1", customerAccessSecret: nil)

        _ = await controller.confirmWallet(token: Data([0x01, 0x02]))

        let req = try XCTUnwrap(payment.lastSubmitRequest)
        XCTAssertEqual(req.walletToken, Data([0x01, 0x02]))
        XCTAssertEqual(req.paymentMethod, "APPLE_PAY")
        XCTAssertNil(req.cardEncryptedData)
        XCTAssertNil(req.savedCardId)
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

    // MARK: - retrievePayment: UI-independent recovery query

    func test_retrievePayment_returnsServerSnapshot() async throws {
        let payment = MockPaymentService()
        payment.stubSession(makeSession())
        payment.stubGetResult([terminalSucceeded(txnId: "txn_recovered")])

        let controller = makeController(payment: payment)
        _ = try await controller.start(sessionId: "sess_1", customerAccessSecret: nil)

        let snapshot = try await controller.retrievePayment(sessionId: "sess_1")

        XCTAssertEqual(snapshot.status, .succeeded)
        XCTAssertEqual(snapshot.txnId, "txn_recovered")
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
