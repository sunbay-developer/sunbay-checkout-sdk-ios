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

    /// Single active session guard (§4.2): `true` means a confirm is in progress.
    ///
    /// Any confirm, on entry, checks and occupies it within the actor isolation domain; a second entry that finds it already occupied →
    /// immediately returns `alreadyPresenting`, does **not** generate a new attemptId, and does **not** call submit.
    private var isConfirming = false

    /// Reconciliation-pending markers (§4.2 "query first, never blindly resend", across attempts).
    ///
    /// Holds the ids of sessions whose last confirm resolved to `.pending` / `.unknown`. While a session
    /// is armed, the NEXT confirm for it must query `getResult` first instead of minting a fresh
    /// attemptId and submitting again. The store is shared by every controller created from the same
    /// `SunbayCheckout` (memory only; see `PendingReconciliationStore`); a controller constructed
    /// without one gets a private store. Cleared whenever the session resolves to a terminal outcome,
    /// whether through a normal submit, the confirm-time gate, or `reconcile(sessionId:)`.
    private let pendingStore: PendingReconciliationStore

    /// Creates the controller.
    ///
    /// - Parameters:
    ///   - paymentService: The backend payment capability (mock/real interchangeable).
    ///   - cofService: The saved-card listing capability.
    ///   - credentials: The in-memory credential holder (cleared on terminal state).
    ///   - actionHandler: The `requiresAction` dispatcher (real implementation provided by Task 8).
    ///   - poller: The pending→terminal result poller (optional). When omitted, it is constructed from the same `paymentService` with `.default`
    ///     parameters; tests may inject a zero-wait-sleep poller to deterministically drive pending polling.
    ///   - pendingStore: The unresolved-outcome markers (optional). `SunbayCheckout` passes its shared store so
    ///     every controller it creates honors the same markers; when omitted the controller owns a private store.
    init(
        paymentService: any PaymentService,
        cofService: any CofService,
        credentials: CredentialStore,
        actionHandler: any ActionHandling,
        poller: ResultPoller? = nil,
        pendingStore: PendingReconciliationStore = PendingReconciliationStore()
    ) {
        self.paymentService = paymentService
        self.cofService = cofService
        self.credentials = credentials
        self.actionHandler = actionHandler
        self.poller = poller ?? ResultPoller(service: paymentService)
        self.pendingStore = pendingStore
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
        guard beginAttempt() else {
            return .failed(txnId: nil, error: CheckoutErrors.alreadyPresenting())
        }
        defer { endAttempt() }
        // Reconcile first if an earlier attempt for this session is still unresolved: no new attemptId, no submit.
        if let reconciled = await reconcileIfPending(sessionId: session.id) {
            return reconciled
        }
        let attemptId = UUID()

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
        guard beginAttempt() else {
            return .failed(txnId: nil, error: CheckoutErrors.alreadyPresenting())
        }
        defer { endAttempt() }
        // Reconcile first if an earlier attempt for this session is still unresolved: no new attemptId, no submit.
        if let reconciled = await reconcileIfPending(sessionId: session.id) {
            return reconciled
        }
        let attemptId = UUID()

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
        guard beginAttempt() else {
            return .failed(txnId: nil, error: CheckoutErrors.alreadyPresenting())
        }
        defer { endAttempt() }
        // Reconcile first if an earlier attempt for this session is still unresolved: no new attemptId, no submit.
        if let reconciled = await reconcileIfPending(sessionId: session.id) {
            return reconciled
        }
        let attemptId = UUID()

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
        isConfirming = false
        session = nil
        await credentials.clear()
    }

    // MARK: - Private: single active guard

    /// Attempts to occupy the single active lock.
    ///
    /// - Returns: `true` on successful occupation; `false` if already occupied (the caller maps this to alreadyPresenting).
    ///
    /// - Note: This method is synchronous with no `await`, atomically completing "check + occupy" within the actor isolation domain.
    ///   This is precisely the carrier of the single active invariant: two concurrent confirms are serialized by the actor, and the second is bound to see `isConfirming == true`.
    ///   The `attemptId` is minted by the caller only AFTER the reconciliation gate passes, so a gated call never mints one.
    private func beginAttempt() -> Bool {
        guard !isConfirming else { return false }
        isConfirming = true
        return true
    }

    /// Releases the single active lock (when one confirm finishes).
    private func endAttempt() {
        isConfirming = false
    }

    // MARK: - Private: reconciliation gate (across attempts)

    /// Reconciliation-first gate, run at the top of every confirm path while the active lock is held.
    ///
    /// If the previous confirm for this session ended `.pending` / `.unknown`, the earlier attempt may
    /// still have succeeded server-side (the response was merely lost), so submitting again risks a
    /// duplicate charge. Instead of minting a new attemptId and calling `submit`, this performs ONE
    /// `getResult` (not an open-ended poll: it runs synchronously in response to a user tap) and maps it
    /// through `resolveReconciled`. A query failure leaves the credential and the marker untouched.
    ///
    /// - Returns: The reconciled outcome, or `nil` when nothing is pending (the caller proceeds normally).
    private func reconcileIfPending(sessionId: String) async -> CheckoutOutcome? {
        guard pendingStore.isArmed(sessionId) else { return nil }
        // Capture the arm generation BEFORE the await: the verdict may only clear the marker it was fetched for.
        let generation = pendingStore.generation(sessionId)

        guard let snapshot = try? await paymentService.getResult(sessionId: sessionId) else {
            return .unknown(sessionId: sessionId)
        }
        return await resolveReconciled(snapshot, sessionId: sessionId, generation: generation)
    }

    /// The single terminal-resolution mapping shared by the confirm-time gate and `reconcile(sessionId:)`,
    /// so the two paths cannot drift:
    /// - terminal `S` → `.succeeded`; marker cleared; credential cleared.
    /// - terminal `F` → `.failed`; marker cleared (the NEXT confirm is a clean fresh attempt); credential cleared.
    /// - `I` / `R` (non-terminal) → `.unknown`; marker and credential untouched.
    ///
    /// The marker is cleared only if it was not re-armed since `generation` was read (before the query's
    /// `await`), so a stale verdict cannot clear a marker a concurrent attempt just set.
    ///
    /// ASSUMPTION (backend contract TBD, product-spec §7): the snapshot is SESSION-level and carries no
    /// attemptId, so a terminal `F` is trusted as the verdict of the LATEST attempt — i.e. a new attempt
    /// moves the session off a previous `F`, and `getResult` reflects the latest attempt. If the backend
    /// can keep returning an older attempt's `F`, compare `snapshot.txnId` to the last attempt's txnId
    /// before disarming (see docs/superpowers/BACKLOG.md).
    private func resolveReconciled(
        _ snapshot: PaymentSnapshot, sessionId: String, generation: UInt64
    ) async -> CheckoutOutcome {
        switch snapshot.status {
        case .succeeded:
            pendingStore.disarm(sessionId, ifGeneration: generation)
            await terminalCleanup()
            return .succeeded(txnId: snapshot.txnId ?? "")
        case .failed:
            pendingStore.disarm(sessionId, ifGeneration: generation)
            await terminalCleanup()
            return .failed(txnId: snapshot.txnId, error: CheckoutErrors.paymentFailed())
        case .initial, .requiresAction:
            return .unknown(sessionId: sessionId)
        }
    }

    // MARK: - Reconciliation (query-only, in-sheet)

    /// Polls the server (bounded, via the injected `ResultPoller`) for the terminal state of a session
    /// whose outcome is unresolved, WITHOUT submitting anything.
    ///
    /// Query-only: it never calls `submit`, never mints an attemptId, and does not take the
    /// active-attempt lock, so a confirm that arrives meanwhile is not blocked (that confirm runs the
    /// gate, which does its own single query). Honors task cancellation (the poller returns promptly).
    ///
    /// - terminal `S` → `.succeeded`; terminal `F` → `.failed` (marker + credential cleared, like the gate);
    /// - still non-terminal at the poll limit, the query keeps failing, or the task was cancelled →
    ///   `.unknown(sessionId:)` and the marker stays set.
    func reconcile(sessionId: String) async -> CheckoutOutcome {
        let generation = pendingStore.generation(sessionId)
        let snapshot = await poller.pollUntilTerminal(sessionId: sessionId)
        return await resolveReconciled(snapshot, sessionId: sessionId, generation: generation)
    }

    // MARK: - Private: submit + result resolution

    /// Submits and resolves the result into a `CheckoutOutcome`.
    ///
    /// "Query first on submit failure" (§4.2): when `submit` throws, it does **not** resend; instead it calls `getResult` once;
    /// if `getResult` also fails → `.unknown`. A successful response is mapped by snapshot status (see `mapSnapshot`).
    /// Each confirm calls this method only once and produces exactly one outcome (result deduplication: the mapping happens only once).
    ///
    /// Arm / disarm of the cross-attempt reconciliation gate is NOT driven by the public outcome alone:
    /// a `.failed` outcome can come from an `ActionHandling` client-side decision (e.g.
    /// `UNSUPPORTED_CAPABILITY`) while the server transaction is still `R` (confirmed, non-terminal).
    /// Disarming there would let the next confirm mint a fresh attemptId and submit again against a
    /// live transaction — exactly the double-submit this gate exists to prevent. So `submitAndMap`
    /// reports whether the snapshot that produced the outcome was itself SERVER-terminal (`S`/`F`),
    /// and only that drives disarm; a non-terminal snapshot (`R` routed to a failing action handler,
    /// or a submit-then-query-failure `.unknown`) arms/keeps the marker regardless of the outcome's
    /// public shape.
    private func submitAndResolve(_ request: SubmitRequest) async -> CheckoutOutcome {
        let (outcome, serverTerminal) = await submitAndMap(request)
        // Arm / disarm the cross-attempt reconciliation gate (single place).
        if serverTerminal {
            pendingStore.disarm(request.sessionId)
        } else {
            switch outcome {
            case .pending, .unknown, .failed:
                pendingStore.arm(request.sessionId)
            case .succeeded, .canceled:
                break
            }
        }
        return outcome
    }

    /// - Returns: The outcome, and whether it was produced from a SERVER-confirmed terminal snapshot
    ///   (`S` / `F`) as opposed to a client-side decision (action-handler failure) or a query failure.
    private func submitAndMap(_ request: SubmitRequest) async -> (CheckoutOutcome, serverTerminal: Bool) {
        let snapshot: PaymentSnapshot
        do {
            snapshot = try await paymentService.submit(request)
        } catch {
            // Query first on failure; never blindly resend the same attemptId.
            do {
                snapshot = try await paymentService.getResult(sessionId: request.sessionId)
            } catch {
                await terminalCleanupIfTerminal(.unknown(sessionId: request.sessionId))
                return (.unknown(sessionId: request.sessionId), false)
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
    /// - `R` → delegate to `ActionHandling`: `.pending` → `.pending`, `.failed(err)` → `.failed` (client-side; NOT server-terminal)
    ///
    /// The second tuple element is `true` only when the outcome came from a server-confirmed terminal status (`S` / `F`).
    private func mapSnapshot(_ snapshot: PaymentSnapshot) async -> (CheckoutOutcome, serverTerminal: Bool) {
        switch snapshot.status {
        case .succeeded:
            let txnId = snapshot.txnId ?? ""
            await terminalCleanup()
            return (.succeeded(txnId: txnId), true)

        case .failed:
            await terminalCleanup()
            return (.failed(txnId: snapshot.txnId, error: CheckoutErrors.paymentFailed()), true)

        case .initial:
            // Non-terminal: poll until a terminal state or the limit (Task 7). Polling uses the injected/default ResultPoller.
            let polled = await poller.pollUntilTerminal(sessionId: snapshot.sessionId)
            switch polled.status {
            case .succeeded:
                await terminalCleanup()
                return (.succeeded(txnId: polled.txnId ?? ""), true)
            case .failed:
                await terminalCleanup()
                return (.failed(txnId: polled.txnId, error: CheckoutErrors.paymentFailed()), true)
            case .initial, .requiresAction:
                // Reached the limit and still non-terminal → unknown (not a failure, §4.3); clear the UI-side credential.
                await terminalCleanup()
                return (.unknown(sessionId: snapshot.sessionId), false)
            }

        case .requiresAction:
            // Obtain the action (seam): use it if the service implementation provides one, otherwise fall back to .unknown (→ unsupported).
            let action = (paymentService as? PaymentActionProviding)?
                .actionForLatestRequiresAction() ?? .unknown
            let result = await actionHandler.handle(action, sessionId: snapshot.sessionId)
            switch result {
            case .pending:
                // requiresAction itself is non-terminal: await return / polling to confirm, do not clear the credential.
                return (.pending(txnId: snapshot.txnId), false)
            case .failed(let error):
                // A CLIENT-side failure (e.g. UNSUPPORTED_CAPABILITY): the server transaction is still `R`.
                // `serverTerminal == false` keeps the reconciliation marker armed (see `submitAndResolve`).
                await terminalCleanup()
                return (.failed(txnId: snapshot.txnId, error: error), false)
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
