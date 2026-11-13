import Foundation

/// Inputs to the session driver that depend on the host UI configuration, expressed without UIKit types.
struct DriverOptions: Sendable {
    /// Whether the host turned the express (wallet) row off; Apple Pay is then not offered.
    var expressOff: Bool

    /// Whether an empty method list (after the host filter and provider availability) is a terminal start
    /// failure (`NO_PAYMENT_METHOD_AVAILABLE`, the sheet's behavior). When `false`, `loadContext()` returns
    /// `.ready` with empty `visibleEntries` and leaves the session alive, so an embedded component can
    /// render its own empty state.
    var failsWhenNoMethodAvailable: Bool

    /// Tells which of the billing / shipping address forms the UI will show, given the loaded session and
    /// whether the host supplied a usable entry for each kind. The UI layer builds it from the appearance
    /// (it needs UIKit-gated types); the driver only forwards the result to the controller.
    var addressFormsShown: @Sendable (
        _ session: CheckoutSession, _ billingEntryUsable: Bool, _ shippingEntryUsable: Bool
    ) -> (billing: Bool, shipping: Bool)

    init(
        expressOff: Bool = false,
        failsWhenNoMethodAvailable: Bool = true,
        addressFormsShown: @escaping @Sendable (CheckoutSession, Bool, Bool) -> (billing: Bool, shipping: Bool)
            = { _, _, _ in (false, false) }
    ) {
        self.expressOff = expressOff
        self.failsWhenNoMethodAvailable = failsWhenNoMethodAvailable
        self.addressFormsShown = addressFormsShown
    }
}

/// The presentation-independent part of a checkout: load the session context, then dispatch a confirm.
///
/// It owns what used to live inside `PaymentSheet` (`loadContext` / `execute` and the close-outcome
/// policy), so every UI shell (the bottom sheet today; an embedded element or a flow controller later)
/// applies the same filtering, card-on-file and host-address rules. It imports no UIKit/PassKit (Core is
/// UI-agnostic) and holds only immutable inputs; all mutable state lives in `CheckoutController`.
///
/// The retry loop (when a presentation ends, how long it stays open) is shell policy and stays in the shell.
final class CheckoutSessionDriver: Sendable {
    private let controller: CheckoutController
    private let sessionId: String
    private let customerAccessSecret: String?
    private let checkoutClientSecret: String?
    private let billingAddress: AddressInput?
    private let shippingAddress: AddressInput?
    private let options: DriverOptions
    private let walletAuthorizer: any WalletAuthorizing
    private let walletMerchantId: String?
    private let paymentMethodFilter: PaymentMethodFilter

    init(
        controller: CheckoutController,
        sessionId: String,
        customerAccessSecret: String?,
        checkoutClientSecret: String?,
        billingAddress: AddressInput?,
        shippingAddress: AddressInput?,
        options: DriverOptions,
        walletAuthorizer: any WalletAuthorizing,
        walletMerchantId: String?,
        paymentMethodFilter: PaymentMethodFilter
    ) {
        self.controller = controller
        self.sessionId = sessionId
        self.customerAccessSecret = customerAccessSecret
        self.checkoutClientSecret = checkoutClientSecret
        self.billingAddress = billingAddress
        self.shippingAddress = shippingAddress
        self.options = options
        self.walletAuthorizer = walletAuthorizer
        self.walletMerchantId = walletMerchantId
        self.paymentMethodFilter = paymentMethodFilter
    }

    // MARK: - Context

    /// Loads the session, applies the host filter and provider availability, decides COF and lists saved
    /// cards. Never produces a payment outcome other than a start failure.
    func loadContext() async -> CheckoutContextResult {
        // 1. Load the session.
        let session: CheckoutSession
        do {
            session = try await controller.start(
                sessionId: sessionId,
                customerAccessSecret: customerAccessSecret,
                checkoutClientSecret: checkoutClientSecret,
                billingAddress: billingAddress,
                shippingAddress: shippingAddress
            )
        } catch let error as CheckoutError {
            return .startFailed(.failed(txnId: nil, error: error))
        } catch {
            return .startFailed(.unknown(sessionId: sessionId))
        }

        // Host filter + provider availability, before any UI. Nothing available -> terminal failure.
        let filtered = PaymentMethodModel.apply(paymentMethodFilter, to: session.methodEntries)
        await controller.reportFilterIgnored(filtered.ignored)
        let expressOff = options.expressOff
        let walletAuthorizer = self.walletAuthorizer
        let walletMerchantId = self.walletMerchantId
        var walletMissing: [String] = []
        let available = PaymentProviderRegistry.available(entries: filtered.entries) { provider in
            guard provider.key == "APPLE_PAY" else { return true }
            guard !expressOff else { return false }
            let availability = ApplePayAvailability.evaluate(
                session: session, hiddenByFilter: false, authorizer: walletAuthorizer,
                merchantId: walletMerchantId)
            walletMissing = availability.missing
            return availability.available
        }
        // The entry survived the filter (this closure only runs for visible entries), so unusable wallet
        // parameters are reported once (deduplicated by the reporter), even when nothing else is available.
        await controller.reportWalletParamsInvalid(missing: walletMissing)
        guard !available.isEmpty || !options.failsWhenNoMethodAvailable else {
            await controller.dismiss()
            return .startFailed(.failed(
                txnId: nil,
                error: CheckoutError(
                    code: "NO_PAYMENT_METHOD_AVAILABLE",
                    message: "No payment method is available for this checkout.",
                    category: .configuration, traceId: nil)))
        }
        let cardAvailable = available.contains { $0.key == "CARD" }

        // 2. Automatic COF inclusion decision: has secret and the backend has COF on -> list cards.
        // A hidden / absent CARD hides saved cards too and skips the list request.
        let cardOnFileEnabled = await controller.isCardOnFileEnabled && cardAvailable
        let saveCardByDefault = await controller.cardOnFileSaveByDefault
        let savedCards: [SavedCard]
        if cardOnFileEnabled {
            savedCards = await controller.listSavedCards()
        } else {
            savedCards = []
        }

        // Host address entries: report incomplete ones once, and tell the UI which are usable (so
        // `.automatic` shows no form for them).
        let billingEntryUsable = await controller.usableHostEntry(.billing) != nil
        let shippingEntryUsable = await controller.usableHostEntry(.shipping) != nil
        let shown = options.addressFormsShown(session, billingEntryUsable, shippingEntryUsable)
        await controller.evaluateHostEntries(
            billingFormShown: shown.billing, shippingFormShown: shown.shipping)

        return .ready(CheckoutSessionContext(
            session: session, savedCards: savedCards,
            cardOnFileEnabled: cardOnFileEnabled, saveCardByDefault: saveCardByDefault,
            billingEntryUsable: billingEntryUsable, shippingEntryUsable: shippingEntryUsable,
            visibleEntries: filtered.entries))
    }

    // MARK: - Confirm

    /// Drives the `controller.confirm*` call (or cancel) for a user action.
    func execute(_ action: CheckoutUserAction) async -> CheckoutAttemptResult {
        switch action {
        case let .confirmNewCard(input, save, billing, shipping, billingFormShown, shippingFormShown):
            // `save` maps to `storeCard` in the controller (sent only when the checkbox is on and COF is effective).
            return .outcome(await controller.confirmNewCard(
                input, save: save, billingAddress: billing, shippingAddress: shipping,
                billingFormShown: billingFormShown, shippingFormShown: shippingFormShown))
        case let .confirmSavedCard(paymentMethodId):
            return .outcome(await controller.confirmSavedCard(paymentMethodId: paymentMethodId))
        case let .confirmWallet(authorization, billingFormShown, shippingFormShown):
            return .outcome(await controller.confirmWallet(
                authorization, billingFormShown: billingFormShown, shippingFormShown: shippingFormShown))
        case .cancel:
            await controller.dismiss()
            return .outcome(.canceled)
        }
    }

    /// Ends the UI session (clears the active state and the credential).
    func dismiss() async {
        await controller.dismiss()
    }

    /// Replaces the host billing / shipping address entries.
    func updateHostAddresses(billing: AddressInput?, shipping: AddressInput?) async {
        await controller.updateHostAddresses(billing: billing, shipping: shipping)
    }

    /// The Apple Pay contacts to request when no address form is shown.
    func walletContactRequest() async -> WalletContactRequest {
        await controller.walletContactRequest(billingFormShown: false, shippingFormShown: false)
    }

    /// A UI-independent result lookup (crash / kill recovery).
    func retrievePayment() async throws -> PaymentSnapshot {
        try await controller.retrievePayment(sessionId: sessionId)
    }

    // MARK: - Close policy

    /// Whether `outcome` is an unsettled `.pending` / `.unknown` (a payment may be in flight).
    static func isUnresolved(_ outcome: CheckoutOutcome) -> Bool {
        switch outcome {
        case .pending, .unknown: return true
        case .succeeded, .failed, .canceled: return false
        }
    }

    /// The outcome to report when the user closes the presentation.
    ///
    /// - Parameter lastKnown: The outcome of the most recent attempt (`.canceled` if none was made).
    /// - Returns: `lastKnown` when it is `.pending` / `.unknown` (an unsettled payment the host must
    ///   reconcile with `retrievePayment()`); otherwise `.canceled`.
    static func outcomeOnClose(lastKnown: CheckoutOutcome) -> CheckoutOutcome {
        switch lastKnown {
        case .pending, .unknown:
            return lastKnown
        case .succeeded, .failed, .canceled:
            return .canceled
        }
    }
}
