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

    /// Card-on-file is not effective (session / host option / credential), so saved-card payment is refused.
    static func cardOnFileUnavailable() -> CheckoutError {
        CheckoutError(
            code: "CARD_ON_FILE_UNAVAILABLE",
            message: "Saved-card payment is unavailable.",
            category: .validation,
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

    /// The default `PAYMENT_FAILED` message used when the server gives no reason.
    static let defaultPaymentFailedMessage = "The payment failed."

    /// Payment failed (mapped from the terminal state `F`; the fallback when the backend gives no finer-grained reason).
    static func paymentFailed(reason: String? = nil) -> CheckoutError {
        let trimmed = reason?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return CheckoutError(
            code: "PAYMENT_FAILED",
            message: trimmed.isEmpty ? defaultPaymentFailedMessage : trimmed,
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
    private let cardOnFile: CardOnFileOptions

    /// Effective card-on-file decision, computed once at `start` and reset on `dismiss`.
    private var cofEffective = false

    /// The currently loaded session; written after `start` succeeds.
    private var session: CheckoutSession?
    /// Diagnostics sink for non-terminal errors (nil when no host channel is wired).
    private let reporter: DiagnosticsReporter?

    /// Sanitized host-provided address entries for the current start (PII; reset at the top of `start`, cleared on `dismiss`).
    private var hostBilling: AddressInput?
    private var hostShipping: AddressInput?

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
    ///   - cardOnFile: Host card-on-file options (default: enabled, not saved by default).
    init(
        paymentService: any PaymentService,
        cofService: any CofService,
        credentials: CredentialStore,
        actionHandler: any ActionHandling,
        cardOnFile: CardOnFileOptions = CardOnFileOptions(),
        reporter: DiagnosticsReporter? = nil
    ) {
        self.reporter = reporter
        self.paymentService = paymentService
        self.cofService = cofService
        self.credentials = credentials
        self.actionHandler = actionHandler
        self.cardOnFile = cardOnFile
    }

    // MARK: - Effective card-on-file decision

    /// Whether card-on-file is effective: the session allows it, the host option is on, and a
    /// `customerAccessSecret` is held. Evaluated at `start`; `false` before `start` and after `dismiss()`.
    var isCardOnFileEnabled: Bool { cofEffective }

    /// Whether the save-card checkbox starts ticked (`false` unless COF is effective).
    var cardOnFileSaveByDefault: Bool { cofEffective && cardOnFile.saveByDefault }

    // MARK: - Lifecycle

    /// Loads the session and starts a UI checkout.
    ///
    /// If `customerAccessSecret` is provided, it is first held in memory (COF); then the session is loaded and validated as not expired.
    ///
    /// - Parameters:
    ///   - sessionId: Session identifier.
    ///   - customerAccessSecret: COF credential (optional); held in memory only, cleared on success / dismiss / session expiry.
    ///   - checkoutClientSecret: Session client secret (optional); held in memory only, cleared together with the other secret.
    ///   - billingAddress: Host billing entry; sanitized and used only when the session collects billing and the entry is complete.
    ///   - shippingAddress: Host shipping entry; same rules as `billingAddress`.
    /// - Returns: The loaded session.
    /// - Throws: Load failures propagate; if the session has expired, throws `CheckoutError` (`.validation`).
    func start(
        sessionId: String,
        customerAccessSecret: String?,
        checkoutClientSecret: String? = nil,
        billingAddress: AddressInput? = nil,
        shippingAddress: AddressInput? = nil
    ) async throws -> CheckoutSession {
        // Reset the previous decision first so a failed / expired re-start never keeps stale COF state.
        session = nil
        cofEffective = false
        hostBilling = AddressRules.sanitize(billingAddress)
        hostShipping = AddressRules.sanitize(shippingAddress)
        resetAddressWarnings()
        reporter?.resetUnscopedErrors()
        reporter?.resetWarnings(containing: CheckoutWarning.Code.walletParamsInvalid.rawValue)
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
        let hasSecret = await credentials.current() != nil
        cofEffective = loaded.cofEnabled && cardOnFile.isEnabled && hasSecret
        return loaded
    }

    /// Lists saved cards (COF).
    ///
    /// Downgrade rules (§2.2 / Task 6): `cofEnabled == false` → return `[]` directly and **never** call `CofService`;
    /// no credential → `[]`; listing throws → swallow it and return `[]` (downgrade to new card only). This method **never** throws.
    ///
    /// - Returns: The list of saved cards, or empty when unavailable / on failure.
    func listSavedCards() async -> [SavedCard] {
        guard let session, cofEffective else {
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
            let reported = (error as? CheckoutError)
                ?? CheckoutError(
                    code: "SAVED_CARDS_FAILED",
                    message: "Saved cards could not be loaded.",
                    category: .network,
                    traceId: nil)
            reporter?.error(reported, sessionId: session.id)
            return []
        }
    }

    // MARK: - The three confirm paths

    /// New-card payment (optionally saving the card).
    ///
    /// Encrypts the card data locally (plaintext lives in memory only at this moment, released with the scope), and submits it as `cardEncryptedData`.
    func confirmNewCard(
        _ input: CardInput,
        save: Bool,
        billingAddress: AddressInput? = nil,
        shippingAddress: AddressInput? = nil,
        billingFormShown: Bool = false,
        shippingFormShown: Bool = false
    ) async -> CheckoutOutcome {
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

        let billing = resolveCardAddress(.billing, form: billingAddress, formShown: billingFormShown)
        let shipping = resolveCardAddress(.shipping, form: shippingAddress, formShown: shippingFormShown)
        let request = SubmitRequest(
            sessionId: session.id,
            paymentMethod: "CARD",
            attemptId: attemptId,
            cardEncryptedData: encrypted,
            storeCard: (save && cofEffective) ? true : nil,
            checkoutClientSecret: await credentials.currentCheckoutClientSecret(),
            sessionType: session.sessionType,
            billingAddress: billing,
            shippingAddress: shipping,
            customerName: AddressRules.customerName(billing: billing, shipping: shipping)
        )
        return await submitAndResolve(request)
    }

    /// COF saved-card quick payment (zero verification). Carries the saved card id (`savedCardId`) and credentials, no card data.
    func confirmSavedCard(paymentMethodId: String) async -> CheckoutOutcome {
        guard let session else {
            return .failed(txnId: nil, error: CheckoutErrors.sessionExpired())
        }
        guard cofEffective else {
            return .failed(txnId: nil, error: CheckoutErrors.cardOnFileUnavailable())
        }
        guard beginAttempt() else {
            return .failed(txnId: nil, error: CheckoutErrors.alreadyPresenting())
        }
        defer { endAttempt() }
        let attemptId = UUID()

        reportIncompleteEntries()
        let billing = usableHostEntry(.billing)
        let shipping = usableHostEntry(.shipping)
        let request = SubmitRequest(
            sessionId: session.id,
            paymentMethod: "TOKEN",
            attemptId: attemptId,
            savedCardId: paymentMethodId,
            customerAccessSecret: await credentials.current(),
            checkoutClientSecret: await credentials.currentCheckoutClientSecret(),
            sessionType: session.sessionType,
            billingAddress: billing,
            shippingAddress: shipping,
            customerName: AddressRules.customerName(billing: billing, shipping: shipping)
        )
        return await submitAndResolve(request)
    }

    /// Apple Pay wallet payment. Carries the wallet token, the resolved addresses and the wallet email.
    ///
    /// Per kind: the contact returned by the wallet wins; otherwise the usable host entry when no SDK form exists for the
    /// kind; when a form exists the entry is ignored (the form cannot be read at tap time) and `ADDRESS_ENTRY_IGNORED` is reported.
    func confirmWallet(
        _ authorization: WalletAuthorization,
        billingFormShown: Bool = false,
        shippingFormShown: Bool = false
    ) async -> CheckoutOutcome {
        guard let session else {
            return .failed(txnId: nil, error: CheckoutErrors.sessionExpired())
        }
        guard beginAttempt() else {
            return .failed(txnId: nil, error: CheckoutErrors.alreadyPresenting())
        }
        defer { endAttempt() }
        let attemptId = UUID()

        reportIncompleteEntries()
        let billing = resolveWalletAddress(.billing, contact: authorization.billing, formShown: billingFormShown)
        let shipping = resolveWalletAddress(.shipping, contact: authorization.shipping, formShown: shippingFormShown)
        let request = SubmitRequest(
            sessionId: session.id,
            paymentMethod: "APPLE_PAY",
            attemptId: attemptId,
            walletToken: authorization.token,
            checkoutClientSecret: await credentials.currentCheckoutClientSecret(),
            sessionType: session.sessionType,
            billingAddress: billing,
            shippingAddress: shipping,
            customerName: AddressRules.customerName(billing: billing, shipping: shipping),
            customerEmail: AddressRules.sanitize(AddressInput(email: authorization.email))?.email
        )
        return await submitAndResolve(request)
    }

    /// Reports `WALLET_PARAMS_INVALID` for the current session (deduplicated by the reporter). `missing` holds parameter
    /// names only, never values.
    func reportWalletParamsInvalid(missing: [String]) {
        guard !missing.isEmpty else { return }
        reporter?.warning(
            .walletParamsInvalid, ignored: missing,
            reason: "Apple Pay is unavailable because the session's wallet parameters are missing or unusable.",
            sessionId: session?.id)
    }

    /// Reports each filter identifier that matched nothing (deduplicated by the reporter). Identifiers only.
    func reportFilterIgnored(_ ignored: [PaymentMethodModel.FilterIgnored]) {
        for item in ignored {
            reporter?.warning(
                .paymentMethodFilterIgnored, ignored: [item.identifier], reason: item.reason, sessionId: session?.id)
        }
    }

    // MARK: - Host address entries

    /// Replaces the host address entries (for example when a standalone Apple Pay button's properties change).
    /// Resets the warning dedup for both kinds so the new values are evaluated afresh.
    func updateHostAddresses(billing: AddressInput?, shipping: AddressInput?) {
        hostBilling = AddressRules.sanitize(billing)
        hostShipping = AddressRules.sanitize(shipping)
        resetAddressWarnings()
        reportIncompleteEntries()
    }

    /// The host entry for `kind` when it may be submitted: the session collects that kind and the entry is complete.
    func usableHostEntry(_ kind: AddressKind) -> AddressInput? {
        guard collects(kind), let entry = hostEntry(kind), AddressRules.isComplete(kind, entry) else { return nil }
        return entry
    }

    /// Reports `ADDRESS_INCOMPLETE` for entries the session collects but that are incomplete.
    ///
    /// It never reports `ADDRESS_ENTRY_IGNORED`: that warning is emitted only by the confirm paths when an entry is
    /// actually overridden (a form draft, or a wallet-supplied address / shown form), because this method cannot see
    /// form drafts. The `*FormShown` parameters are kept for API stability and are intentionally unused here.
    func evaluateHostEntries(billingFormShown: Bool, shippingFormShown: Bool) {
        reportIncompleteEntries()
    }

    /// The Apple Pay contacts to request: per kind, `collect && (no usable host entry || a form is shown)`.
    func walletContactRequest(billingFormShown: Bool, shippingFormShown: Bool) -> WalletContactRequest {
        WalletContactRequest(
            billing: collects(.billing) && (usableHostEntry(.billing) == nil || billingFormShown),
            shipping: collects(.shipping) && (usableHostEntry(.shipping) == nil || shippingFormShown))
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
        cofEffective = false
        hostBilling = nil
        hostShipping = nil
        resetAddressWarnings()
        reporter?.resetUnscopedErrors()
        reporter?.resetWarnings(containing: CheckoutWarning.Code.walletParamsInvalid.rawValue)
        await credentials.clear()
    }

    // MARK: - Private: address resolution

    private func collects(_ kind: AddressKind) -> Bool {
        switch kind {
        case .billing: return session?.collectBillingAddress ?? false
        case .shipping: return session?.collectShippingAddress ?? false
        }
    }

    private func hostEntry(_ kind: AddressKind) -> AddressInput? {
        kind == .billing ? hostBilling : hostShipping
    }

    /// Card: a form draft beats the host entry (which is then reported as ignored); a country-only form value is not a
    /// draft, so the usable entry is used; with neither, the form value (if a form exists) is submitted.
    private func resolveCardAddress(_ kind: AddressKind, form: AddressInput?, formShown: Bool) -> AddressInput? {
        reportIncompleteEntries(kind)
        let value = AddressRules.sanitize(form)
        let entry = usableHostEntry(kind)
        if AddressRules.hasDraftContent(value) {
            if hostEntry(kind) != nil { reportIgnored(kind) }
            return value
        }
        return entry ?? (formShown ? value : nil)
    }

    /// Wallet: the returned contact wins; else the usable entry when no form exists for the kind.
    private func resolveWalletAddress(_ kind: AddressKind, contact: AddressInput?, formShown: Bool) -> AddressInput? {
        // The warning is about the entry's presence: a shown form means the entry is ignored for the wallet.
        if formShown, hostEntry(kind) != nil { reportIgnored(kind) }
        if let contact = AddressRules.sanitize(contact) { return contact }
        guard !formShown else { return nil }
        return usableHostEntry(kind)
    }

    private func reportIncompleteEntries() {
        reportIncompleteEntries(.billing)
        reportIncompleteEntries(.shipping)
    }

    private func reportIncompleteEntries(_ kind: AddressKind) {
        guard collects(kind), hostEntry(kind) != nil, usableHostEntry(kind) == nil else { return }
        reporter?.warning(
            .addressIncomplete, ignored: [kind.identifier],
            reason: "The \(kind.identifier) is missing required fields and was not used.",
            sessionId: session?.id)
    }

    private func reportIgnored(_ kind: AddressKind) {
        reporter?.warning(
            .addressEntryIgnored, ignored: [kind.identifier],
            reason: "The \(kind.identifier) was ignored because the checkout collects this address itself.",
            sessionId: session?.id)
    }

    private func resetAddressWarnings() {
        reporter?.resetWarnings(containing: AddressKind.billing.identifier)
        reporter?.resetWarnings(containing: AddressKind.shipping.identifier)
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
            return .failed(txnId: snapshot.txnId, error: CheckoutErrors.paymentFailed(reason: snapshot.failureReason))

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
