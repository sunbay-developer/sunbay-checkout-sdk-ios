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
        expiresAt: Date = Date().addingTimeInterval(600),
        collectBilling: Bool = false,
        collectShipping: Bool = false
    ) -> CheckoutSession {
        CheckoutSession(
            id: id,
            amount: Amount(minorUnits: 999, currencyCode: "USD"),
            merchantName: "Acme",
            methods: [.card, .applePay],
            expiresAt: expiresAt,
            rsaPublicKey: rsaPublicKey,
            cofEnabled: cofEnabled,
            sessionType: "sdk",
            collectBillingAddress: collectBilling,
            collectShippingAddress: collectShipping
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
        cardOnFile: CardOnFileOptions = CardOnFileOptions(),
        reporter: DiagnosticsReporter? = nil
    ) -> CheckoutController {
        CheckoutController(
            paymentService: payment,
            cofService: cof,
            credentials: credentials,
            actionHandler: actionHandler,
            cardOnFile: cardOnFile,
            reporter: reporter
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
        _ = try await controller.start(sessionId: "sess_1", customerAccessSecret: "cas_1")

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
        _ = try await controller.start(sessionId: "sess_1", customerAccessSecret: "cas_1")

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
        _ = try await controller.start(sessionId: "sess_1", customerAccessSecret: "cas_1")

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
        _ = try await controller.start(sessionId: "sess_1", customerAccessSecret: "cas_1")

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
        _ = try await controller.start(sessionId: "sess_1", customerAccessSecret: "cas_1")

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
        _ = try await controller.start(sessionId: "sess_1", customerAccessSecret: "cas_1")

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
        _ = try await controller.start(sessionId: "sess_1", customerAccessSecret: "cas_1")

        _ = await controller.confirmNewCard(newCardInput(), save: false)

        let req = try XCTUnwrap(payment.lastSubmitRequest)
        XCTAssertNotNil(req.cardEncryptedData)
        XCTAssertFalse(req.cardEncryptedData?.isEmpty ?? true, "a new card should carry non-empty ciphertext")
        XCTAssertNil(req.savedCardId, "a new card must not carry savedCardId")
        XCTAssertNil(req.walletToken)
    }

    // MARK: - sessionType is echoed from the loaded session on every path

    func test_allPaths_submitSessionTypeFromLoadedSession() async throws {
        let rsaKey = try makeRSAPublicKey()
        let payment = MockPaymentService()
        payment.stubSession(makeSession(rsaPublicKey: rsaKey))
        payment.stubSubmit([terminalSucceeded()])
        var controller = makeController(payment: payment)
        _ = try await controller.start(sessionId: "sess_1", customerAccessSecret: "cas_1")
        _ = await controller.confirmNewCard(newCardInput(), save: false)
        XCTAssertEqual(payment.lastSubmitRequest?.sessionType, "sdk")

        payment.stubSubmit([terminalSucceeded()])
        controller = makeController(payment: payment)
        _ = try await controller.start(sessionId: "sess_1", customerAccessSecret: "cas_1")
        _ = await controller.confirmSavedCard(paymentMethodId: "sc_1")
        XCTAssertEqual(payment.lastSubmitRequest?.sessionType, "sdk")

        payment.stubSubmit([terminalSucceeded()])
        controller = makeController(payment: payment)
        _ = try await controller.start(sessionId: "sess_1", customerAccessSecret: "cas_1")
        _ = await controller.confirmWallet(WalletAuthorization(token: Data("{}".utf8), billing: nil, shipping: nil, email: nil))
        XCTAssertEqual(payment.lastSubmitRequest?.sessionType, "sdk")
    }

    // MARK: - Saved card: carry only paymentMethodId, no card data

    func test_savedCard_submitsSavedCardId_noCardData() async throws {
        let payment = MockPaymentService()
        payment.stubSession(makeSession())
        payment.stubSubmit([terminalSucceeded()])

        let controller = makeController(payment: payment)
        _ = try await controller.start(sessionId: "sess_1", customerAccessSecret: "cas_1")

        _ = await controller.confirmSavedCard(paymentMethodId: "pm_42")

        let req = try XCTUnwrap(payment.lastSubmitRequest)
        XCTAssertEqual(req.savedCardId, "pm_42")
        XCTAssertEqual(req.paymentMethod, "TOKEN")
        XCTAssertNil(req.cardEncryptedData, "a saved card must not carry card ciphertext")
        XCTAssertNil(req.walletToken)
    }


    // MARK: - Diagnostics

    func test_listSavedCards_failure_returnsEmptyAndReportsError() async throws {
        let payment = MockPaymentService()
        payment.stubSession(makeSession(cofEnabled: true))
        let cof = MockCofService()
        cof.stubError(CheckoutError(code: "COF_DOWN", message: "down", category: .network, traceId: nil))
        let reporter = DiagnosticsReporter()
        let e = expectation(description: "diagnostic")
        nonisolated(unsafe) var received: [CheckoutDiagnostic] = []
        reporter.handler = { received.append($0); e.fulfill() }
        let controller = makeController(payment: payment, cof: cof, reporter: reporter)
        _ = try await controller.start(sessionId: "sess_1", customerAccessSecret: "cas_1")

        let cards = await controller.listSavedCards()

        XCTAssertEqual(cards, [])
        await fulfillment(of: [e], timeout: 2)
        XCTAssertEqual(received.count, 1)
        guard case .error(let error, let sessionId) = received[0] else { return XCTFail("expected error") }
        XCTAssertEqual(error.code, "COF_DOWN")
        XCTAssertEqual(sessionId, "sess_1")
    }

    // MARK: - Real submit contract (Task 4)

    func test_newCard_saveTrue_cofDisabled_storeCardNil() async throws {
        let payment = MockPaymentService()
        payment.stubSession(makeSession(cofEnabled: false, rsaPublicKey: try makeRSAPublicKey()))
        payment.stubSubmit([terminalSucceeded()])
        let controller = makeController(payment: payment)
        _ = try await controller.start(sessionId: "sess_1", customerAccessSecret: "cas_1")

        _ = await controller.confirmNewCard(newCardInput(), save: true)

        XCTAssertNil(payment.lastSubmitRequest?.storeCard)
    }

    func test_newCard_saveTrue_cofEnabled_storeCardTrue() async throws {
        let payment = MockPaymentService()
        payment.stubSession(makeSession(cofEnabled: true, rsaPublicKey: try makeRSAPublicKey()))
        payment.stubSubmit([terminalSucceeded()])
        let controller = makeController(payment: payment)
        _ = try await controller.start(sessionId: "sess_1", customerAccessSecret: "cas_1")

        _ = await controller.confirmNewCard(newCardInput(), save: true)

        XCTAssertEqual(payment.lastSubmitRequest?.storeCard, true)
    }

    func test_newCard_saveFalse_cofEnabled_storeCardNil() async throws {
        let payment = MockPaymentService()
        payment.stubSession(makeSession(cofEnabled: true, rsaPublicKey: try makeRSAPublicKey()))
        payment.stubSubmit([terminalSucceeded()])
        let controller = makeController(payment: payment)
        _ = try await controller.start(sessionId: "sess_1", customerAccessSecret: "cas_1")

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
        _ = try await controller.start(sessionId: "sess_1", customerAccessSecret: "cas_1")

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
        _ = try await controller.start(sessionId: "sess_1", customerAccessSecret: "cas_1")

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
        _ = try await controller.start(sessionId: "sess_1", customerAccessSecret: "cas_1")

        _ = await controller.confirmWallet(WalletAuthorization(token: Data([0x01, 0x02]), billing: nil, shipping: nil, email: nil))

        let req = try XCTUnwrap(payment.lastSubmitRequest)
        XCTAssertEqual(req.walletToken, Data([0x01, 0x02]))
        XCTAssertEqual(req.paymentMethod, "APPLE_PAY")
        XCTAssertNil(req.cardEncryptedData)
        XCTAssertNil(req.savedCardId)
    }

    // MARK: - Addresses (JS rules: form draft > host entry; entry only when collected and complete)

    private func addr(_ line: String) -> AddressInput { AddressInput(country: "US", line1: line) }

    private func fullBilling(_ line: String = "1 Main St") -> AddressInput {
        AddressInput(country: "US", line1: line, city: "San Jose", postalCode: "95112")
    }

    private func fullShipping(_ line: String = "2 Side St") -> AddressInput {
        AddressInput(
            country: "US", line1: line, city: "Austin", postalCode: "73301",
            firstName: "Ada", lastName: "Lovelace", phone: "5551234")
    }

    private final class WarningBox: @unchecked Sendable {
        private let lock = NSLock()
        private var items: [CheckoutWarning] = []
        func add(_ d: CheckoutDiagnostic) {
            if case let .warning(w) = d { lock.lock(); items.append(w); lock.unlock() }
        }
        var all: [CheckoutWarning] { lock.lock(); defer { lock.unlock() }; return items }
    }

    private struct AddressRig {
        let payment: MockPaymentService
        let controller: CheckoutController
        let warnings: WarningBox

        /// Waits for the reporter's main-queue deliveries issued so far.
        func warningsFlushed() async -> [CheckoutWarning] {
            await MainActor.run {}
            return warnings.all
        }
    }

    private func addressRig(
        collectBilling: Bool, collectShipping: Bool = false,
        billing: AddressInput? = nil, shipping: AddressInput? = nil
    ) async throws -> AddressRig {
        let payment = MockPaymentService()
        payment.stubSession(makeSession(
            rsaPublicKey: try makeRSAPublicKey(), collectBilling: collectBilling,
            collectShipping: collectShipping))
        payment.stubSubmit([PaymentSnapshot(sessionId: "sess_1", status: .failed, txnId: nil)])
        let warnings = WarningBox()
        let reporter = DiagnosticsReporter()
        reporter.handler = { warnings.add($0) }
        let controller = makeController(payment: payment, reporter: reporter)
        _ = try await controller.start(
            sessionId: "sess_1", customerAccessSecret: "cas_1",
            billingAddress: billing, shippingAddress: shipping)
        return AddressRig(payment: payment, controller: controller, warnings: warnings)
    }

    func test_address_notCollected_entryIsNotSubmittedAndSilent() async throws {
        let rig = try await addressRig(collectBilling: false, billing: fullBilling())
        _ = await rig.controller.confirmNewCard(newCardInput(), save: false)
        XCTAssertNil(rig.payment.lastSubmitRequest?.billingAddress)
        let warnings = await rig.warningsFlushed()
        XCTAssertTrue(warnings.isEmpty)
    }

    func test_address_collectedButIncomplete_reportsOnceAndSubmitsNone() async throws {
        let rig = try await addressRig(collectBilling: true, billing: addr("1 Main St"))
        _ = await rig.controller.confirmNewCard(newCardInput(), save: false)
        _ = await rig.controller.confirmNewCard(newCardInput(), save: false)
        XCTAssertNil(rig.payment.lastSubmitRequest?.billingAddress)
        let warnings = await rig.warningsFlushed()
        XCTAssertEqual(warnings.map(\.code), [.addressIncomplete])
        XCTAssertEqual(warnings.first?.ignored, ["billingAddress"])
        XCTAssertEqual(warnings.first?.sessionId, "sess_1")
    }

    func test_address_card_usableEntrySubmittedWhenNoForm() async throws {
        let rig = try await addressRig(collectBilling: true, billing: fullBilling())
        _ = await rig.controller.confirmNewCard(newCardInput(), save: false)
        XCTAssertEqual(rig.payment.lastSubmitRequest?.billingAddress, fullBilling())
    }

    func test_address_card_draftBeatsEntryAndReportsIgnoredOnce() async throws {
        let rig = try await addressRig(collectBilling: true, billing: fullBilling("Entry"))
        let draft = AddressInput(country: "US", line1: " Draft ")
        _ = await rig.controller.confirmNewCard(
            newCardInput(), save: false, billingAddress: draft, billingFormShown: true)
        _ = await rig.controller.confirmNewCard(
            newCardInput(), save: false, billingAddress: draft, billingFormShown: true)
        XCTAssertEqual(rig.payment.lastSubmitRequest?.billingAddress, addr("Draft"))
        let warnings = await rig.warningsFlushed()
        XCTAssertEqual(warnings.map(\.code), [.addressEntryIgnored])
        XCTAssertEqual(warnings.first?.ignored, ["billingAddress"])
    }

    func test_address_card_countryOnlyFormValueFallsBackToEntry() async throws {
        let rig = try await addressRig(collectBilling: true, billing: fullBilling())
        _ = await rig.controller.confirmNewCard(
            newCardInput(), save: false, billingAddress: AddressInput(country: "CA"), billingFormShown: true)
        XCTAssertEqual(rig.payment.lastSubmitRequest?.billingAddress, fullBilling())
        let warnings = await rig.warningsFlushed()
        XCTAssertTrue(warnings.isEmpty)
    }

    func test_address_savedCard_usesUsableEntries() async throws {
        let rig = try await addressRig(
            collectBilling: true, collectShipping: false, billing: fullBilling(), shipping: fullShipping())
        _ = await rig.controller.confirmSavedCard(paymentMethodId: "pm")
        XCTAssertEqual(rig.payment.lastSubmitRequest?.billingAddress, fullBilling())
        XCTAssertNil(rig.payment.lastSubmitRequest?.shippingAddress)
    }

    func test_address_wallet_walletContactBeatsEntry() async throws {
        let rig = try await addressRig(collectBilling: true, billing: fullBilling("Entry"))
        let auth = WalletAuthorization(
            token: Data([1]), billing: fullBilling("Wallet"), shipping: nil, email: nil)
        _ = await rig.controller.confirmWallet(auth)
        XCTAssertEqual(rig.payment.lastSubmitRequest?.billingAddress, fullBilling("Wallet"))
    }

    func test_address_wallet_entryUsedWhenNoFormAndNoContact() async throws {
        let rig = try await addressRig(collectBilling: false, collectShipping: true, shipping: fullShipping())
        let auth = WalletAuthorization(token: Data([1]), billing: nil, shipping: nil, email: nil)
        _ = await rig.controller.confirmWallet(auth)
        XCTAssertEqual(rig.payment.lastSubmitRequest?.shippingAddress, fullShipping())
    }

    func test_address_wallet_formShownIgnoresEntryAndReports() async throws {
        let rig = try await addressRig(collectBilling: false, collectShipping: true, shipping: fullShipping())
        let auth = WalletAuthorization(token: Data([1]), billing: nil, shipping: nil, email: nil)
        _ = await rig.controller.confirmWallet(auth, shippingFormShown: true)
        XCTAssertNil(rig.payment.lastSubmitRequest?.shippingAddress)
        let warnings = await rig.warningsFlushed()
        XCTAssertEqual(warnings.map(\.code), [.addressEntryIgnored])
        XCTAssertEqual(warnings.first?.ignored, ["shippingAddress"])
    }

    func test_address_walletContactRequest_table() async throws {
        // collect false: never requested, even with a form shown
        var rig = try await addressRig(collectBilling: false, collectShipping: false)
        var req = await rig.controller.walletContactRequest(billingFormShown: true, shippingFormShown: true)
        XCTAssertEqual(req, WalletContactRequest(billing: false, shipping: false))

        // collect true, no entry: requested
        rig = try await addressRig(collectBilling: true, collectShipping: true)
        req = await rig.controller.walletContactRequest(billingFormShown: false, shippingFormShown: false)
        XCTAssertEqual(req, WalletContactRequest(billing: true, shipping: true))

        // collect true, usable entry: not requested unless a form is shown
        rig = try await addressRig(
            collectBilling: true, collectShipping: true, billing: fullBilling(), shipping: fullShipping())
        req = await rig.controller.walletContactRequest(billingFormShown: false, shippingFormShown: false)
        XCTAssertEqual(req, WalletContactRequest(billing: false, shipping: false))
        req = await rig.controller.walletContactRequest(billingFormShown: true, shippingFormShown: false)
        XCTAssertEqual(req, WalletContactRequest(billing: true, shipping: false))

        // collect true, incomplete entry: counts as absent
        rig = try await addressRig(collectBilling: true, billing: addr("x"))
        req = await rig.controller.walletContactRequest(billingFormShown: false, shippingFormShown: false)
        XCTAssertEqual(req, WalletContactRequest(billing: true, shipping: false))
    }

    func test_address_customerNameAndEmailAreSubmitted() async throws {
        let rig = try await addressRig(collectBilling: false, collectShipping: true)
        let auth = WalletAuthorization(
            token: Data([1]), billing: nil, shipping: fullShipping(), email: "ada@example.com")
        _ = await rig.controller.confirmWallet(auth)
        XCTAssertEqual(rig.payment.lastSubmitRequest?.customerName, "Ada Lovelace")
        XCTAssertEqual(rig.payment.lastSubmitRequest?.customerEmail, "ada@example.com")

        _ = await rig.controller.confirmSavedCard(paymentMethodId: "pm")
        XCTAssertNil(rig.payment.lastSubmitRequest?.customerEmail)
    }

    func test_address_secondStartClearsEntriesAndDedup() async throws {
        let rig = try await addressRig(collectBilling: true, billing: addr("x"))
        _ = await rig.controller.confirmNewCard(newCardInput(), save: false)
        _ = try await rig.controller.start(sessionId: "sess_1", customerAccessSecret: nil)
        _ = await rig.controller.confirmNewCard(newCardInput(), save: false)
        XCTAssertNil(rig.payment.lastSubmitRequest?.billingAddress)

        _ = try await rig.controller.start(
            sessionId: "sess_1", customerAccessSecret: nil, billingAddress: addr("y"))
        _ = await rig.controller.confirmNewCard(newCardInput(), save: false)
        let warnings = await rig.warningsFlushed()
        XCTAssertEqual(warnings.map(\.code), [.addressIncomplete, .addressIncomplete])
    }

    func test_address_requestDescriptionIsRedacted() {
        let request = SubmitRequest(
            sessionId: "s", paymentMethod: "CARD", attemptId: UUID(),
            billingAddress: AddressInput(line1: "1 Main St", email: "a@b.c"),
            shippingAddress: AddressInput(line1: "1 Main St", email: "a@b.c"),
            customerName: "Ada Lovelace", customerEmail: "ada@b.c")
        for text in [String(reflecting: request), "\(request)", String(describing: request)] {
            XCTAssertFalse(text.contains("1 Main St"))
            XCTAssertFalse(text.contains("a@b.c"))
            XCTAssertFalse(text.contains("Ada"))
            XCTAssertFalse(text.contains("ada@b.c"))
        }
        XCTAssertTrue(Mirror(reflecting: request).children.isEmpty)
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

    // MARK: - Success clears credentials

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
        XCTAssertNil(held, "credentials should be cleared after success")
    }

    // MARK: - Secret lifetime (ruling R7)

    func test_definiteFailure_keepsSecrets_secondWalletSubmitStillCarriesClientSecret() async throws {
        let payment = MockPaymentService()
        payment.stubSession(makeSession())
        payment.stubSubmitError(
            CheckoutError(code: "CARD_DECLINED", message: "x", category: .payment, traceId: nil))
        let controller = makeController(payment: payment)
        _ = try await controller.start(
            sessionId: "sess_1", customerAccessSecret: "cas_1", checkoutClientSecret: "ccs_1")

        let first = await controller.confirmWallet(WalletAuthorization(token: Data([1]), billing: nil, shipping: nil, email: nil))
        guard case .failed = first else { return XCTFail("expected failed, got \(first)") }
        _ = await controller.confirmWallet(WalletAuthorization(token: Data([2]), billing: nil, shipping: nil, email: nil))

        let req = try XCTUnwrap(payment.lastSubmitRequest)
        XCTAssertEqual(req.checkoutClientSecret, "ccs_1")
    }

    func test_unknown_keepsSecrets_secondWalletSubmitStillCarriesClientSecret() async throws {
        let payment = MockPaymentService()
        payment.stubSession(makeSession())
        payment.stubSubmitError(URLError(.timedOut))
        payment.stubGetResultError(URLError(.timedOut))
        let controller = makeController(payment: payment)
        _ = try await controller.start(
            sessionId: "sess_1", customerAccessSecret: "cas_1", checkoutClientSecret: "ccs_1")

        let first = await controller.confirmWallet(WalletAuthorization(token: Data([1]), billing: nil, shipping: nil, email: nil))
        guard case .unknown = first else { return XCTFail("expected unknown, got \(first)") }
        _ = await controller.confirmWallet(WalletAuthorization(token: Data([2]), billing: nil, shipping: nil, email: nil))

        let req = try XCTUnwrap(payment.lastSubmitRequest)
        XCTAssertEqual(req.checkoutClientSecret, "ccs_1")
    }

    func test_succeeded_emptiesStore() async throws {
        let payment = MockPaymentService()
        payment.stubSession(makeSession())
        payment.stubSubmit([terminalSucceeded()])
        let credentials = CredentialStore()
        let controller = makeController(payment: payment, credentials: credentials)
        _ = try await controller.start(
            sessionId: "sess_1", customerAccessSecret: "cas_1", checkoutClientSecret: "ccs_1")

        _ = await controller.confirmWallet(WalletAuthorization(token: Data([1]), billing: nil, shipping: nil, email: nil))

        let cas = await credentials.current()
        let ccs = await credentials.currentCheckoutClientSecret()
        XCTAssertNil(cas)
        XCTAssertNil(ccs)
    }

    func test_dismiss_emptiesStore_afterFailure() async throws {
        let payment = MockPaymentService()
        payment.stubSession(makeSession())
        payment.stubSubmitError(
            CheckoutError(code: "CARD_DECLINED", message: "x", category: .payment, traceId: nil))
        let credentials = CredentialStore()
        let controller = makeController(payment: payment, credentials: credentials)
        _ = try await controller.start(
            sessionId: "sess_1", customerAccessSecret: "cas_1", checkoutClientSecret: "ccs_1")
        _ = await controller.confirmWallet(WalletAuthorization(token: Data([1]), billing: nil, shipping: nil, email: nil))
        let keptCcs = await credentials.currentCheckoutClientSecret()
        XCTAssertEqual(keptCcs, "ccs_1")

        await controller.dismiss()

        let cas = await credentials.current()
        let ccs = await credentials.currentCheckoutClientSecret()
        XCTAssertNil(cas)
        XCTAssertNil(ccs)
    }

    // MARK: - start: an expired session should throw

    func test_start_expiredSession_throws() async throws {
        let payment = MockPaymentService()
        payment.stubSession(makeSession(expiresAt: Date().addingTimeInterval(-10)))

        let controller = makeController(payment: payment)

        do {
            _ = try await controller.start(sessionId: "sess_1", customerAccessSecret: "cas_1")
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
        _ = try await controller.start(sessionId: "sess_1", customerAccessSecret: "cas_1")

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
        _ = try await controller.start(sessionId: "sess_1", customerAccessSecret: "cas_1")

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
        _ = try await controller.start(sessionId: "sess_1", customerAccessSecret: "cas_1")

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

    // MARK: - Effective COF decision

    private struct CofRig {
        let controller: CheckoutController
        let payment: MockPaymentService
        let cof: MockCofService
    }

    private func makeCofRig(
        sessionCof: Bool,
        options: CardOnFileOptions = CardOnFileOptions(),
        secret: String? = "cas_1"
    ) async throws -> CofRig {
        let payment = MockPaymentService()
        payment.stubSession(makeSession(cofEnabled: sessionCof, rsaPublicKey: try makeRSAPublicKey()))
        payment.stubSubmit([terminalSucceeded()])
        let cof = MockCofService()
        let controller = makeController(payment: payment, cof: cof, cardOnFile: options)
        _ = try await controller.start(sessionId: "sess_1", customerAccessSecret: secret)
        return CofRig(controller: controller, payment: payment, cof: cof)
    }

    func test_effectiveCof_sessionAndOptionsAndSecret_enabled() async throws {
        let rig = try await makeCofRig(sessionCof: true)
        let enabled = await rig.controller.isCardOnFileEnabled
        XCTAssertTrue(enabled)
        _ = await rig.controller.listSavedCards()
        XCTAssertEqual(rig.cof.listCallCount, 1)
    }

    func test_effectiveCof_sessionDisabled_blocksListAndStoreCard() async throws {
        let rig = try await makeCofRig(sessionCof: false)
        let enabled = await rig.controller.isCardOnFileEnabled
        XCTAssertFalse(enabled)
        _ = await rig.controller.listSavedCards()
        XCTAssertEqual(rig.cof.listCallCount, 0)
        _ = await rig.controller.confirmNewCard(newCardInput(), save: true)
        XCTAssertNil(rig.payment.lastSubmitRequest?.storeCard)
    }

    func test_effectiveCof_hostDisabled_blocksListAndStoreCard() async throws {
        let rig = try await makeCofRig(sessionCof: true, options: CardOnFileOptions(isEnabled: false))
        let enabled = await rig.controller.isCardOnFileEnabled
        XCTAssertFalse(enabled)
        _ = await rig.controller.listSavedCards()
        XCTAssertEqual(rig.cof.listCallCount, 0)
        _ = await rig.controller.confirmNewCard(newCardInput(), save: true)
        XCTAssertNil(rig.payment.lastSubmitRequest?.storeCard)
    }

    func test_effectiveCof_noSecret_disabled() async throws {
        let rig = try await makeCofRig(sessionCof: true, secret: nil)
        let enabled = await rig.controller.isCardOnFileEnabled
        XCTAssertFalse(enabled)
        _ = await rig.controller.listSavedCards()
        XCTAssertEqual(rig.cof.listCallCount, 0)
        _ = await rig.controller.confirmNewCard(newCardInput(), save: true)
        XCTAssertNil(rig.payment.lastSubmitRequest?.storeCard)
    }

    func test_confirmSavedCard_hostDisabled_failsWithoutSubmit() async throws {
        let rig = try await makeCofRig(sessionCof: true, options: CardOnFileOptions(isEnabled: false))
        let outcome = await rig.controller.confirmSavedCard(paymentMethodId: "card_1")
        guard case let .failed(_, error) = outcome else { return XCTFail("expected failed, got \(outcome)") }
        XCTAssertEqual(error.code, "CARD_ON_FILE_UNAVAILABLE")
        XCTAssertEqual(error.category, .validation)
        XCTAssertEqual(rig.payment.submitCallCount, 0)
    }

    func test_restart_failure_resetsEffectiveCof() async throws {
        let rig = try await makeCofRig(sessionCof: true)
        let first = await rig.controller.isCardOnFileEnabled
        XCTAssertTrue(first)
        rig.payment.stubLoadError(NSError(domain: "t", code: 1))
        do {
            _ = try await rig.controller.start(sessionId: "sess_1", customerAccessSecret: "cas_1")
            XCTFail("expected start to throw")
        } catch {}
        let second = await rig.controller.isCardOnFileEnabled
        XCTAssertFalse(second)
    }

    func test_effectiveCof_enabled_storeCardSentWhenSaveTrue() async throws {
        let rig = try await makeCofRig(sessionCof: true)
        _ = await rig.controller.confirmNewCard(newCardInput(), save: true)
        XCTAssertEqual(rig.payment.lastSubmitRequest?.storeCard, true)
    }

    func test_saveByDefault_requiresEffectiveCof() async throws {
        let on = try await makeCofRig(sessionCof: true, options: CardOnFileOptions(saveByDefault: true))
        let onValue = await on.controller.cardOnFileSaveByDefault
        XCTAssertTrue(onValue)
        let off = try await makeCofRig(sessionCof: false, options: CardOnFileOptions(saveByDefault: true))
        let offValue = await off.controller.cardOnFileSaveByDefault
        XCTAssertFalse(offValue)
    }

    func test_effectiveCof_falseBeforeStartAndAfterDismiss() async throws {
        let payment = MockPaymentService()
        payment.stubSession(makeSession())
        let controller = makeController(payment: payment)
        let before = await controller.isCardOnFileEnabled
        XCTAssertFalse(before)
        _ = try await controller.start(sessionId: "sess_1", customerAccessSecret: "cas_1")
        let during = await controller.isCardOnFileEnabled
        XCTAssertTrue(during)
        await controller.dismiss()
        let after = await controller.isCardOnFileEnabled
        XCTAssertFalse(after)
    }
}
