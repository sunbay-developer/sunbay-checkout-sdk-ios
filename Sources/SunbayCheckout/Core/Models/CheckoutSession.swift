import Foundation

/// Core domain model for a single checkout session.
///
/// A UI-agnostic domain model, decoded from the backend session JSON, carrying
/// all the information needed to render the available payment methods and to
/// confirm a payment.
///
/// - Note: Public (`public`) since Task 11.5: a host-provided `PaymentService.loadSession`
///   implementation must return this type, so it is part of the public service contract.
///   The fields it carries (amount / merchant / methods / expiry / public key / COF switch)
///   are all non-secret; `rsaPublicKey` is a **public key** (not a private key) and is
///   exposed as a plain `public let`.
public struct CheckoutSession: Sendable, Equatable {
    /// Session identifier.
    public let id: String
    /// The amount of this payment.
    public let amount: Amount
    /// Merchant display name.
    public let merchantName: String
    /// The set of payment methods available for this session.
    public let methods: Set<PaymentMethodKind>
    /// Session expiry time.
    public let expiresAt: Date
    /// RSA **public key** (base64) used to locally encrypt card data; nil when unavailable. The public key is non-secret.
    public let rsaPublicKey: String?
    /// Whether COF (saved card / one-tap) is enabled.
    public let cofEnabled: Bool

    /// Creates a checkout session (constructed and returned by the host's `PaymentService.loadSession`).
    ///
    /// - Parameters:
    ///   - id: Session identifier.
    ///   - amount: The amount of this payment.
    ///   - merchantName: Merchant display name.
    ///   - methods: The set of payment methods available for this session.
    ///   - expiresAt: Session expiry time.
    ///   - rsaPublicKey: RSA public key (base64) used to locally encrypt card data, defaults to nil.
    ///   - cofEnabled: Whether COF is enabled, defaults to false.
    public init(
        id: String,
        amount: Amount,
        merchantName: String,
        methods: Set<PaymentMethodKind>,
        expiresAt: Date,
        rsaPublicKey: String? = nil,
        cofEnabled: Bool = false
    ) {
        self.id = id
        self.amount = amount
        self.merchantName = merchantName
        self.methods = methods
        self.expiresAt = expiresAt
        self.rsaPublicKey = rsaPublicKey
        self.cofEnabled = cofEnabled
    }
}

/// Payment method type.
///
/// Public since Task 11.5: crosses the public boundary via `CheckoutSession.methods`.
public enum PaymentMethodKind: String, Sendable {
    /// New card.
    case card
    /// Apple Pay wallet.
    case applePay
    /// Saved card (COF).
    case savedCard
}
