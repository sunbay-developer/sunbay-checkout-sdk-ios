import Foundation

/// The actions the user can select during one checkout (produced by the content UI / test seam).
///
/// internal: used only to pass user intent between the UI shells and the presentation-independent
/// session logic; never exposed externally. `PaymentSheet.UserAction` is a typealias of this type.
enum CheckoutUserAction: Sendable {
    /// Confirm a new card (optionally checked to save + consent).
    ///
    /// `billingFormShown` / `shippingFormShown` say whether the SDK showed a form for that kind.
    case confirmNewCard(
        CardInput, save: Bool, billing: AddressInput? = nil, shipping: AddressInput? = nil,
        billingFormShown: Bool = false, shippingFormShown: Bool = false)
    /// Pay with a selected saved card (COF; the user selects a card then taps Pay).
    case confirmSavedCard(paymentMethodId: String)
    /// The Apple Pay wallet token has been obtained; confirm the wallet payment.
    case confirmWallet(WalletAuthorization, billingFormShown: Bool = false, shippingFormShown: Bool = false)
    /// The user canceled.
    case cancel
}

/// What one pass of a checkout attempt produced.
enum CheckoutAttemptResult: Sendable, Equatable {
    /// The session (re)load failed before any confirm was attempted. NOT a payment outcome.
    case startFailed(CheckoutOutcome)
    /// A confirm (or a cancel) produced this outcome.
    case outcome(CheckoutOutcome)
}

/// The context handed to the UI: the loaded session and the (per COF decision) listed saved cards.
struct CheckoutSessionContext: Sendable {
    /// The loaded session, validated as not expired.
    let session: CheckoutSession
    /// The listed saved cards; empty when COF is unavailable (no secret / off).
    let savedCards: [SavedCard]
    /// The effective card-on-file decision (session && host option && secret).
    let cardOnFileEnabled: Bool
    /// Whether the save-card checkbox starts ticked.
    let saveCardByDefault: Bool
    /// Whether the host supplied a complete billing address the session collects.
    var billingEntryUsable: Bool = false
    /// Whether the host supplied a complete shipping address the session collects.
    var shippingEntryUsable: Bool = false
    /// The session's method entries after the host filter (what the UI may offer).
    var visibleEntries: [MethodEntry] = []
}

/// What loading the checkout context produced.
enum CheckoutContextResult {
    /// The session loaded and at least one payment method is available.
    case ready(CheckoutSessionContext)
    /// The session load (or method availability) failed before any confirm. NOT a payment outcome.
    case startFailed(CheckoutOutcome)
}
