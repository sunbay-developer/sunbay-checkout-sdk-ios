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
/// The three payment paths (new card / Apple Pay / COF saved card) share the same state machine, idempotency key, and
/// result mapping. `actor` isolation naturally serializes execution, satisfying the concurrency invariant (§4.2) without
/// hand-written locks.
///
/// ## Submit lock & no client polling (realignment 2026-11-06)
/// The single-active lock (`isConfirming`) covers ONLY the in-flight submit request (plus the one-shot query-on-failure
/// and the synchronous result mapping) and is released the moment the confirm returns — it never waits on a poll or a
/// backend terminal state. The SDK does NOT client-poll for the result: a non-terminal `I` submit result maps straight to
/// `.pending`, and the host reconciles later via `retrievePayment` / webhook. Duplicate-charge protection rests on (1)
/// holding the lock while one submit is in flight and (2) the backend deduping by `attemptId` / `txnId` — not on freezing
/// the UI. See `docs/superpowers/specs/2026-11-06-submit-lock-and-no-poll-realignment-design.md`.
///
/// All dependencies are protocol-injected (`PaymentService` / `CofService` / `ActionHandling`) plus cohesive boundaries
/// (`CredentialStore` holds the secret, `CardEncryptor` touches plaintext cards). This class imports no UIKit/PassKit
/// (Core is UI-agnostic, AGENTS.md §2.6).
actor CheckoutController {
    private let paymentService: any PaymentService
    private let cofService: any CofService
    private let credentials: CredentialStore
    private let actionHandler: any ActionHandling

    /// The currently loaded session; written after `start` succeeds.
    private var session: CheckoutSession?

    /// Single active session guard (§4.2): `true` means a confirm is in progress.
    ///
    /// Any confirm, on entry, checks and occupies it within the actor isolation domain; a second entry that finds it already occupied →
    /// immediately returns `alreadyPresenting`, does **not** generate a new attemptId, and does **not** call submit.
    private var isConfirming = false

    /// Creates the controller.
    ///
    /// - Parameters:
    ///   - paymentService: The backend payment capability (mock/real interchangeable).
    ///   - cofService: The saved-card listing capability.
    ///   - credentials: The in-memory credential holder (cleared on success / dismiss / expiry).
    ///   - actionHandler: The `requiresAction` dispatcher.
    init(
        paymentService: any PaymentService,
        cofService: any CofService,
        credentials: CredentialStore,
        actionHandler: any ActionHandling
    ) {
        self.paymentService = paymentService
        self.cofService = cofService
        self.credentials = credentials
        self.actionHandler = actionHandler
    }

    // MARK: - Lifecycle

    /// Loads the session and starts a UI checkout.
    ///
    /// If `customerAccessSecret` is provided, it is first held in memory (COF); then the session is loaded and validated as not expired.
    ///
    /// - Parameters:
    ///   - sessionId: Session identifier.
    ///   - customerAccessSecret: COF credential (optional); held in memory only, cleared on success / dismiss / session expiry.
    ///   - checkoutClientSecret: Session client secret (optional); held in memory only, cleared together with the other secret.
    /// - Returns: The loaded session.
    /// - Throws: Load failures propagate; if the session has expired, throws `CheckoutError` (`.validation`).
    func start(
        sessionId: String,
        customerAccessSecret: String?,
        checkoutClientSecret: String? = nil
    ) async throws -> CheckoutSession {
        if let secret = customerAccessSecret {
            await credentials.hold(customerAccessSecret: secret)
        }
        if let clientSecret = checkoutClientSecret {
            await credentials.hold(checkoutClientSecret: clientSecret)
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
    func confirmNewCard(_ input: CardInput, save: Bool) async -> CheckoutOutcome {
        guard let session else {
            return .failed(txnId: nil, error: CheckoutErrors.sessionExpired())
        }
        guard beginAttempt() else {
            return .failed(txnId: nil, error: CheckoutErrors.alreadyPresenting())
        }
        defer { endAttempt() }
        let attemptId = UUID()

        // Encryption (§7.2): missing public key or encryption failure → do not submit, fail directly (terminal state, clear the credential).
        guard let rsaKey = session.rsaPublicKey else {
            return .failed(txnId: nil, error: CheckoutErrors.encryptionFailed())
        }
        let encrypted: String
        do {
            encrypted = try CardEncryptor.encrypt(input, rsaPublicKeyBase64: rsaKey)
        } catch {
            return .failed(txnId: nil, error: CheckoutErrors.encryptionFailed())
        }

        let request = SubmitRequest(
            sessionId: session.id,
            paymentMethod: "CARD",
            attemptId: attemptId,
            cardEncryptedData: encrypted,
            storeCard: (save && session.cofEnabled) ? true : nil,
            checkoutClientSecret: await credentials.currentCheckoutClientSecret(),
            sessionType: session.sessionType
        )
        return await submitAndResolve(request)
    }

    /// COF saved-card quick payment (zero verification). Carries the saved card id (`savedCardId`) and credentials, no card data.
    func confirmSavedCard(paymentMethodId: String) async -> CheckoutOutcome {
        guard let session else {
            return .failed(txnId: nil, error: CheckoutErrors.sessionExpired())
        }
        guard beginAttempt() else {
            return .failed(txnId: nil, error: CheckoutErrors.alreadyPresenting())
        }
        defer { endAttempt() }
        let attemptId = UUID()

        let request = SubmitRequest(
            sessionId: session.id,
            paymentMethod: "TOKEN",
            attemptId: attemptId,
            savedCardId: paymentMethodId,
            customerAccessSecret: await credentials.current(),
            checkoutClientSecret: await credentials.currentCheckoutClientSecret(),
            sessionType: session.sessionType
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
        let attemptId = UUID()

        let request = SubmitRequest(
            sessionId: session.id,
            paymentMethod: "APPLE_PAY",
            attemptId: attemptId,
            walletToken: token,
            checkoutClientSecret: await credentials.currentCheckoutClientSecret(),
            sessionType: session.sessionType
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
    private func beginAttempt() -> Bool {
        guard !isConfirming else { return false }
        isConfirming = true
        return true
    }

    /// Releases the single active lock (when one confirm finishes).
    private func endAttempt() {
        isConfirming = false
    }

    // MARK: - Private: submit + result resolution

    /// Submits and maps the result into a `CheckoutOutcome`. Each confirm calls this once.
    ///
    /// "Query once on submit failure": when `submit` throws, it does **not** resend the same
    /// attemptId; it queries `getResult` once (to recover a lost response within this same in-flight
    /// attempt). If that query also fails → `.unknown`. The lock (held by the caller's
    /// `defer { endAttempt() }`) spans only this in-flight submit + the one-shot query + the
    /// synchronous mapping; it never waits on a poll or a backend terminal state.
    private func submitAndResolve(_ request: SubmitRequest) async -> CheckoutOutcome {
        let snapshot: PaymentSnapshot
        do {
            snapshot = try await paymentService.submit(request)
        } catch let error as CheckoutError where error.category != .network {
            // Definite server rejection: nothing was charged and the outcome is known; no result query.
            // Secrets are kept so the host-visible retry (e.g. a second Apple Pay tap) still carries them.
            return .failed(txnId: nil, error: error)
        } catch {
            // Query once on failure; never blindly resend the same attemptId.
            do {
                snapshot = try await paymentService.getResult(sessionId: request.sessionId)
            } catch {
                return .unknown(sessionId: request.sessionId)
            }
        }
        return await mapSnapshot(snapshot)
    }

    /// Snapshot → outcome mapping.
    ///
    /// - `S` → `.succeeded` (terminal, clear secrets)
    /// - `F` → `.failed` (secrets kept for retry)
    /// - `I` → `.pending`: the request returned non-terminal. The SDK does NOT poll — it reports
    ///   `pending` immediately and the host reconciles via `retrievePayment` / webhook. Secrets are kept.
    /// - `R` → delegate to `ActionHandling`: `.pending` → `.pending`, `.failed(err)` → `.failed` (secrets kept).
    private func mapSnapshot(_ snapshot: PaymentSnapshot) async -> CheckoutOutcome {
        switch snapshot.status {
        case .succeeded:
            let txnId = snapshot.txnId ?? ""
            await terminalCleanup()
            return .succeeded(txnId: txnId)

        case .failed:
            return .failed(txnId: snapshot.txnId, error: CheckoutErrors.paymentFailed())

        case .initial:
            // Non-terminal: report pending at once (no client polling); the host resolves the final
            // state out of band. Secrets are not cleared (only success / dismiss / expiry clear them).
            return .pending(txnId: snapshot.txnId)

        case .requiresAction:
            // Obtain the action (seam): use it if the service implementation provides one, otherwise fall back to .unknown (→ unsupported).
            let action = (paymentService as? PaymentActionProviding)?
                .actionForLatestRequiresAction() ?? .unknown
            let result = await actionHandler.handle(action, sessionId: snapshot.sessionId)
            switch result {
            case .pending:
                // requiresAction itself is non-terminal: await the host / webhook; do not clear the credential.
                return .pending(txnId: snapshot.txnId)
            case .failed(let error):
                return .failed(txnId: snapshot.txnId, error: error)
            }
        }
    }

    /// Success cleanup: clears both secrets (a charged session needs no further retry). Secrets are NOT cleared on
    /// `.failed` / `.unknown` / `.pending` (ruling R7) so a host-visible retry still carries them; they are cleared
    /// only here, on `dismiss()` and on session expiry. The active lock is released by each confirm's `defer`.
    private func terminalCleanup() async {
        await credentials.clear()
    }
}
