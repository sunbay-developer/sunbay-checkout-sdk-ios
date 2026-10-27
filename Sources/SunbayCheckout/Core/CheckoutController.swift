import Foundation

/// Optional "R snapshot → action" query seam.
///
/// ## Why this seam is needed
/// Task 2's `PaymentSnapshot` deliberately carries only `sessionId / status / txnId`, without `action`;
/// Task 3's `PaymentService.submit / getResult` also return only `PaymentSnapshot`. But §4.5 requires
/// handing the `PaymentAction` to `ActionHandling` for dispatch when `txnStatus == "R"` (requiresAction).
///
/// To let the controller obtain the action **without modifying** Task 2's `PaymentSnapshot` and **without changing**
/// Task 3's `PaymentService` protocol signatures, an **optional** protocol is introduced here: a concrete
/// implementation of `PaymentService` **may** additionally conform to it, returning "the `PaymentAction` corresponding
/// to the most recently returned R snapshot". The controller probes via `paymentService as? PaymentActionProviding`:
/// - conforms → takes the action it returns (treated as `.unknown` when none);
/// - does not conform → no action information is available, falls back to `.unknown` (which `ActionHandling` maps to unsupported).
///
/// The real adapter (once the backend is ready) can internally use `ContractDecoding.decodeResult` first to obtain
/// `ResultEnvelope { snapshot, action }`, return `snapshot` from `submit/getResult`, and at the same time conform to this protocol
/// to expose `action` — the contract is identical to the existing `ResultEnvelope`, with no change to existing types.
protocol PaymentActionProviding: Sendable {
    /// Returns the further action corresponding to the most recent `R` (requiresAction) snapshot; nil when none.
    func actionForLatestRequiresAction() -> PaymentAction?
}

/// The `CheckoutError` factory used internally by Core.
///
/// Centralizes construction of the small set of errors this task needs, ensuring the code / category stay stable and consistent (see the code conventions in §7.7).
/// Carries no sensitive data (§5).
enum CheckoutErrors {
    /// A checkout is already in progress (single active session invariant, §4.2).
    static func alreadyPresenting() -> CheckoutError {
        CheckoutError(
            code: "ALREADY_PRESENTING",
            message: "A checkout is already in progress.",
            category: .runtime,
            traceId: nil
        )
    }

    /// Network unavailable / submit or query failed.
    static func networkUnavailable() -> CheckoutError {
        CheckoutError(
            code: "NETWORK_UNAVAILABLE",
            message: "The network is unavailable.",
            category: .network,
            traceId: nil
        )
    }

    /// Session invalid / expired.
    static func sessionExpired() -> CheckoutError {
        CheckoutError(
            code: "CHECKOUT_EXPIRED",
            message: "The checkout session has expired.",
            category: .validation,
            traceId: nil
        )
    }

    /// Payment failed (mapped from the terminal state `F`; the fallback when the backend gives no finer-grained reason).
    static func paymentFailed() -> CheckoutError {
        CheckoutError(
            code: "PAYMENT_FAILED",
            message: "The payment failed.",
            category: .payment,
            traceId: nil
        )
    }

    /// Local card encryption failed (new-card path, missing public key or an encryption error).
    static func encryptionFailed() -> CheckoutError {
        CheckoutError(
            code: "CARD_ENCRYPTION_FAILED",
            message: "Failed to prepare card data.",
            category: .runtime,
            traceId: nil
        )
    }
}

/// The single UI-agnostic payment orchestrator (product-spec §1 / §4).
///
/// The three payment paths (new card / Apple Pay / COF saved card) share the same state machine, idempotency key,
/// result deduplication, and "query first on submit failure" logic. `actor` isolation naturally serializes execution,
/// satisfying the concurrency invariant (§4.2) without hand-written locks.
///
/// All dependencies are protocol-injected (`PaymentService` / `CofService` / `ActionHandling`) plus cohesive boundaries
/// (`CredentialStore` holds the secret, `CardEncryptor` touches plaintext cards). This class imports no UIKit/PassKit
/// (Core is UI-agnostic, AGENTS.md §2.6).
actor CheckoutController {
    private let paymentService: any PaymentService
    private let cofService: any CofService
    private let credentials: CredentialStore
    private let actionHandler: any ActionHandling

    /// The result poller from pending (`I`) → terminal state (§4.4).
    ///
    /// Injectable (tests use a zero-wait sleep to make polling deterministic without actually sleeping); when not injected,
    /// it is constructed from the same `paymentService` with default parameters, so the production path works without passing it in explicitly.
    private let poller: ResultPoller

    /// The currently loaded session; written after `start` succeeds.
    private var session: CheckoutSession?

    /// Single active session guard (§4.2): non-nil means a confirm is in progress.
    ///
    /// Any confirm, on entry, checks and occupies it within the actor isolation domain; a second entry that finds it already occupied →
    /// immediately returns `alreadyPresenting`, does **not** generate a new attemptId, and does **not** call submit.
    private var activeAttempt: UUID?

    /// Creates the controller.
    ///
    /// - Parameters:
    ///   - paymentService: The backend payment capability (mock/real interchangeable).
    ///   - cofService: The saved-card listing capability.
    ///   - credentials: The in-memory credential holder (cleared on terminal state).
    ///   - actionHandler: The `requiresAction` dispatcher (real implementation provided by Task 8).
    ///   - poller: The pending→terminal result poller (optional). When omitted, it is constructed from the same `paymentService` with `.default`
    ///     parameters; tests may inject a zero-wait-sleep poller to deterministically drive pending polling.
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

    // MARK: - Lifecycle

    /// Loads the session and starts a UI checkout.
    ///
    /// If `customerAccessSecret` is provided, it is first held in memory (COF); then the session is loaded and validated as not expired.
    ///
    /// - Parameters:
    ///   - sessionId: Session identifier.
    ///   - customerAccessSecret: COF credential (optional); held in memory only, cleared on terminal state / close.
    /// - Returns: The loaded session.
    /// - Throws: Load failures propagate; if the session has expired, throws `CheckoutError` (`.validation`).
    func start(sessionId: String, customerAccessSecret: String?) async throws -> CheckoutSession {
        if let secret = customerAccessSecret {
            await credentials.hold(customerAccessSecret: secret)
        }

        let loaded = try await paymentService.loadSession(sessionId)

        // Validate not expired (§3.1: validate the session is valid / not expired).
        guard loaded.expiresAt > Date() else {
            // Expired → clear the credential (§4.2 cleared on terminal state / close / expiry).
            await credentials.clear()
            throw CheckoutErrors.sessionExpired()
        }

        session = loaded
        return loaded
    }

    /// Lists saved cards (COF).
    ///
    /// Downgrade rules (§2.2 / Task 6): `cofEnabled == false` → return `[]` directly and **never** call `CofService`;
    /// no credential → `[]`; listing throws → swallow it and return `[]` (downgrade to new card only). This method **never** throws.
    ///
    /// - Returns: The list of saved cards, or empty when unavailable / on failure.
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
            // Downgrade: do not throw, fall back to new card only.
            return []
        }
    }

    // MARK: - The three confirm paths

    /// New-card payment (optionally saving the card).
    ///
    /// Encrypts the card data locally (plaintext lives in memory only at this moment, released with the scope), and submits it as `cardEncryptedData`.
    func confirmNewCard(_ input: CardInput, save: Bool, consent: Consent?) async -> CheckoutOutcome {
        guard let session else {
            return .failed(txnId: nil, error: CheckoutErrors.sessionExpired())
        }
        guard let attemptId = beginAttempt() else {
            return .failed(txnId: nil, error: CheckoutErrors.alreadyPresenting())
        }
        defer { endAttempt() }

        // Encryption (§7.2): missing public key or encryption failure → do not submit, fail directly (terminal state, clear the credential).
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

    /// COF saved-card quick payment (zero verification). Carries only `paymentMethodId`, no card data.
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

    /// Apple Pay wallet payment. Carries only `walletToken`.
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

    // MARK: - Query / close

    /// UI-independent result query (crash / kill recovery, §4.3).
    func retrievePayment(sessionId: String) async throws -> PaymentSnapshot {
        try await paymentService.getResult(sessionId: sessionId)
    }

    /// Ends the UI session: clears the active state and the credential. Does **not** cancel the server-side transaction (per spec).
    func dismiss() async {
        activeAttempt = nil
        session = nil
        await credentials.clear()
    }

    // MARK: - Private: single active guard

    /// Attempts to occupy the single active lock and generate one attemptId.
    ///
    /// - Returns: Returns a new `attemptId` on successful occupation; returns nil if already occupied (the caller maps this to alreadyPresenting).
    ///
    /// - Note: This method is synchronous with no `await`, atomically completing "check + occupy + generate key" within the actor isolation domain.
    ///   This is precisely the carrier of the single active invariant: two concurrent confirms are serialized by the actor, and the second is bound to see `activeAttempt != nil`.
    private func beginAttempt() -> UUID? {
        guard activeAttempt == nil else { return nil }
        let id = UUID()
        activeAttempt = id
        return id
    }

    /// Releases the single active lock (when one confirm finishes).
    private func endAttempt() {
        activeAttempt = nil
    }

    // MARK: - Private: submit + result resolution

    /// Submits and resolves the result into a `CheckoutOutcome`.
    ///
    /// "Query first on submit failure" (§4.2): when `submit` throws, it does **not** resend; instead it calls `getResult` once;
    /// if `getResult` also fails → `.unknown`. A successful response is mapped by snapshot status (see `mapSnapshot`).
    /// Each confirm calls this method only once and produces exactly one outcome (result deduplication: the mapping happens only once).
    private func submitAndResolve(_ request: SubmitRequest) async -> CheckoutOutcome {
        let snapshot: PaymentSnapshot
        do {
            snapshot = try await paymentService.submit(request)
        } catch {
            // Query first on failure; never blindly resend the same attemptId.
            do {
                snapshot = try await paymentService.getResult(sessionId: request.sessionId)
            } catch {
                await terminalCleanupIfTerminal(.unknown(sessionId: request.sessionId))
                return .unknown(sessionId: request.sessionId)
            }
        }
        return await mapSnapshot(snapshot)
    }

    /// Snapshot → outcome mapping (§4.5 / §7.4).
    ///
    /// - `S` → `.succeeded` (terminal, clear credential)
    /// - `F` → `.failed` (terminal, clear credential)
    /// - `I` → non-terminal: drive `ResultPoller` to poll until a terminal state or the limit (§4.4), then map the polling result:
    ///   terminal → succeeded/failed (clear credential); reached the limit and still non-terminal → `.unknown` (clear credential)
    /// - `R` → delegate to `ActionHandling`: `.pending` → `.pending`, `.failed(err)` → `.failed`
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
            // Non-terminal: poll until a terminal state or the limit (Task 7). Polling uses the injected/default ResultPoller.
            let polled = await poller.pollUntilTerminal(sessionId: snapshot.sessionId)
            switch polled.status {
            case .succeeded:
                await terminalCleanup()
                return .succeeded(txnId: polled.txnId ?? "")
            case .failed:
                await terminalCleanup()
                return .failed(txnId: polled.txnId, error: CheckoutErrors.paymentFailed())
            case .initial, .requiresAction:
                // Reached the limit and still non-terminal → unknown (not a failure, §4.3); clear the UI-side credential.
                await terminalCleanup()
                return .unknown(sessionId: snapshot.sessionId)
            }

        case .requiresAction:
            // Obtain the action (seam): use it if the service implementation provides one, otherwise fall back to .unknown (→ unsupported).
            let action = (paymentService as? PaymentActionProviding)?
                .actionForLatestRequiresAction() ?? .unknown
            let result = await actionHandler.handle(action, sessionId: snapshot.sessionId)
            switch result {
            case .pending:
                // requiresAction itself is non-terminal: await return / polling to confirm, do not clear the credential.
                return .pending(txnId: snapshot.txnId)
            case .failed(let error):
                await terminalCleanup()
                return .failed(txnId: snapshot.txnId, error: error)
            }
        }
    }

    /// Terminal cleanup: clear the credential (§4.2 cleared on terminal state). The active lock is released by each confirm's `defer { endAttempt() }`.
    private func terminalCleanup() async {
        await credentials.clear()
    }

    /// Cleans up if the given outcome is terminal. `unknown` is not a transaction terminal state, but per spec the UI-side credential should also be cleared on a network interruption:
    /// here `unknown` likewise clears the credential (the session can no longer be advanced in this UI).
    private func terminalCleanupIfTerminal(_ outcome: CheckoutOutcome) async {
        switch outcome {
        case .succeeded, .failed, .unknown:
            await credentials.clear()
        case .pending, .canceled:
            break
        }
    }
}
