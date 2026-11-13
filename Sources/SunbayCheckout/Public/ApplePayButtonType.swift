/// The wording on the Apple Pay button, following Apple's Human Interface Guidelines
/// ("Buy with Apple Pay", "Donate with Apple Pay", and so on).
///
/// Used by `Appearance.applePayButtonType` for the PaymentSheet's Apple Pay row and by
/// `ExpressCheckoutElement.Configuration.buttonType` for the embedded button. The text itself is
/// rendered and localized by PassKit.
public enum ApplePayButtonType: Sendable, CaseIterable {
    /// The Apple Pay logo only.
    case plain
    /// "Buy with Apple Pay".
    case buy
    /// "Set up Apple Pay".
    case setUp
    /// "Pay with Apple Pay" (in-store wording).
    case inStore
    /// "Donate with Apple Pay".
    case donate
    /// "Check out with Apple Pay".
    case checkout
    /// "Book with Apple Pay".
    case book
    /// "Subscribe with Apple Pay".
    case subscribe
    /// "Reload with Apple Pay".
    case reload
    /// "Add money with Apple Pay".
    case addMoney
    /// "Top up with Apple Pay".
    case topUp
    /// "Order with Apple Pay".
    case order
    /// "Rent with Apple Pay".
    case rent
    /// "Support with Apple Pay".
    case support
    /// "Contribute with Apple Pay".
    case contribute
    /// "Tip with Apple Pay".
    case tip
}
