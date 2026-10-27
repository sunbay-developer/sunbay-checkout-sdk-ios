import Foundation

/// User consent information attached when saving a card (COF).
///
/// Corresponds to the `consent` field in the product-spec §7.3 request body. Required when saving (`save`) a new card.
///
/// - Note: **Public** since Task 11.5: part of the contract a host `PaymentService` must satisfy, carried with `SubmitRequest`.
public struct Consent: Codable, Sendable {
    /// Consent terms version.
    public let version: String
    /// Future usage; currently fixed to `"ON_SESSION"`.
    public let futureUsage: String

    /// Creates a consent record.
    ///
    /// - Parameters:
    ///   - version: Consent terms version.
    ///   - futureUsage: Future usage, defaults to `"ON_SESSION"`.
    public init(version: String, futureUsage: String = "ON_SESSION") {
        self.version = version
        self.futureUsage = futureUsage
    }
}

/// A single payment submission request (Core internal representation).
///
/// Corresponds to the submission contract in product-spec §7.3 and the COF extension. Carries the fields
/// required by the three payment paths: new card (`cardEncryptedData`), wallet (`walletToken`), saved card (`paymentMethodId`).
///
/// - Note: Sensitive fields (`cardEncryptedData` / `walletToken`) never enter logs or public callbacks (see §5).
///   **Public** since Task 11.5: the host's `PaymentService.submit` receives this type and forwards it to the backend adapter
///   (the host service is itself the backend adapter and legitimately holds these fields to forward).
public struct SubmitRequest: Sendable {
    /// Session identifier.
    public let sessionId: String
    /// Payment method identifier (such as `"VISA"` / `"APPLE_PAY"`).
    public let paymentMethod: String
    /// The attempt identifier for this confirmation; one is generated per confirm, used for idempotency and deduplication.
    public let attemptId: UUID
    /// Card ciphertext (§7.2); used by the new-card path, nil for other paths.
    public let cardEncryptedData: String?
    /// Wallet token (Apple Pay); nil for other paths.
    public let walletToken: Data?
    /// Saved card identifier (COF); nil for other paths. Mutually exclusive with `savePaymentMethod`.
    public let paymentMethodId: String?
    /// Whether to request saving when using a new card (COF).
    public let savePaymentMethod: Bool?
    /// The user consent when saving a card; should be provided when `savePaymentMethod == true`.
    public let consent: Consent?

    /// Creates a payment submission request.
    ///
    /// - Parameters:
    ///   - sessionId: Session identifier.
    ///   - paymentMethod: Payment method identifier.
    ///   - attemptId: The attempt identifier for this confirmation.
    ///   - cardEncryptedData: Card ciphertext, defaults to nil.
    ///   - walletToken: Wallet token, defaults to nil.
    ///   - paymentMethodId: Saved card identifier, defaults to nil.
    ///   - savePaymentMethod: Whether to request saving a new card, defaults to nil.
    ///   - consent: Card-saving consent information, defaults to nil.
    public init(
        sessionId: String,
        paymentMethod: String,
        attemptId: UUID,
        cardEncryptedData: String? = nil,
        walletToken: Data? = nil,
        paymentMethodId: String? = nil,
        savePaymentMethod: Bool? = nil,
        consent: Consent? = nil
    ) {
        self.sessionId = sessionId
        self.paymentMethod = paymentMethod
        self.attemptId = attemptId
        self.cardEncryptedData = cardEncryptedData
        self.walletToken = walletToken
        self.paymentMethodId = paymentMethodId
        self.savePaymentMethod = savePaymentMethod
        self.consent = consent
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
