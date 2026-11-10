import Foundation

/// A single payment submission request (Core internal representation).
///
/// Mirrors the real submit contract. Carries the fields required by the three payment paths:
/// new card (`cardEncryptedData`), wallet (`walletToken`), saved card (`paymentMethod == "TOKEN"` + `savedCardId`).
///
/// - Note: Sensitive fields (`cardEncryptedData` / `walletToken` / `customerAccessSecret` / `checkoutClientSecret`)
///   never enter logs or public callbacks; `debugDescription` redacts them.
///   **Public**: the host's `PaymentService.submit` receives this type and forwards it to the backend adapter.
public struct SubmitRequest: Sendable, CustomStringConvertible, CustomDebugStringConvertible, CustomReflectable {
    /// Session identifier.
    public let sessionId: String
    /// Payment method identifier (such as `"CARD"` / `"APPLE_PAY"` / `"TOKEN"`).
    public let paymentMethod: String
    /// The attempt identifier for this confirmation; one is generated per confirm, used for idempotency and deduplication.
    public let attemptId: UUID
    /// Card ciphertext; used by the new-card path, nil for other paths.
    public let cardEncryptedData: String?
    /// Wallet token (Apple Pay); nil for other paths.
    public let walletToken: Data?
    /// Saved card identifier (COF); nil for other paths.
    public let savedCardId: String?
    /// Whether to store the new card; `true` only when requested and COF is enabled, otherwise nil.
    public let storeCard: Bool?
    /// Short-lived customer credential for the saved-card path; nil otherwise.
    public let customerAccessSecret: String?
    /// Client secret of the checkout session; nil when not provided.
    public let checkoutClientSecret: String?
    /// Backend session type from the loaded session (for example `"sdk"`); the submit API requires it.
    public let sessionType: String?
    /// Billing address to submit (PII; never printed or reflected); nil when none.
    public let billingAddress: AddressInput?
    /// Shipping address to submit (PII; never printed or reflected); nil when none.
    public let shippingAddress: AddressInput?
    /// Customer full name derived from the resolved addresses (PII; never printed or reflected); nil when unknown.
    public let customerName: String?
    /// Customer email from the wallet contact (PII; never printed or reflected); nil when unknown.
    public let customerEmail: String?

    /// Creates a payment submission request.
    public init(
        sessionId: String,
        paymentMethod: String,
        attemptId: UUID,
        cardEncryptedData: String? = nil,
        walletToken: Data? = nil,
        savedCardId: String? = nil,
        storeCard: Bool? = nil,
        customerAccessSecret: String? = nil,
        checkoutClientSecret: String? = nil,
        sessionType: String? = nil,
        billingAddress: AddressInput? = nil,
        shippingAddress: AddressInput? = nil,
        customerName: String? = nil,
        customerEmail: String? = nil
    ) {
        self.sessionId = sessionId
        self.paymentMethod = paymentMethod
        self.attemptId = attemptId
        self.cardEncryptedData = cardEncryptedData
        self.walletToken = walletToken
        self.savedCardId = savedCardId
        self.storeCard = storeCard
        self.customerAccessSecret = customerAccessSecret
        self.checkoutClientSecret = checkoutClientSecret
        self.sessionType = sessionType
        self.billingAddress = billingAddress
        self.shippingAddress = shippingAddress
        self.customerName = customerName
        self.customerEmail = customerEmail
    }

    /// Redacted description: never prints secrets, tokens or ciphertext.
    public var debugDescription: String { redactedDescription }

    /// Redacted description used by `"\(request)"`, `print`, and `String(describing:)`.
    public var description: String { redactedDescription }

    /// Empty mirror so `dump(_:)` and reflection-based loggers cannot enumerate secret fields.
    public var customMirror: Mirror { Mirror(self, children: [:]) }

    private var redactedDescription: String {
        "SubmitRequest(sessionId: \(sessionId), paymentMethod: \(paymentMethod), attemptId: \(attemptId))"
    }
}

/// Backend payment capability contract (UI-agnostic).
///
/// Corresponds to product-spec §7.1 (load session), §7.3 (submit), §7.4 (query result). The first version
/// uses a mock implementation; once the real interface is ready, only the adapter is replaced, leaving Core/UI untouched.
///
/// - Note: **Public** since Task 11.5: the host (and the example app) inject their own implementation (mock or a real
///   backend adapter) via `SunbayCheckout(configuration:paymentService:cofService:)` to drive the end-to-end payment flow.
///   The SDK itself does not provide a real HTTP adapter (the backend contract is undefined, §7/§8).
public protocol PaymentService: Sendable {
    /// Loads the specified session.
    func loadSession(_ id: String) async throws -> CheckoutSession
    /// Submits a payment.
    func submit(_ req: SubmitRequest) async throws -> PaymentSnapshot
    /// Queries the payment result.
    func getResult(sessionId: String) async throws -> PaymentSnapshot
}
