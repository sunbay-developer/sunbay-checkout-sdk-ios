import Foundation

/// Encodes an Apple Pay token for the `cardEncryptedData` field. The wire format for wallet tokens
/// is still an open question; keeping it in one function means a change touches only this place.
enum WalletTokenEncoder {
    /// Returns the token JSON as a UTF-8 string.
    static func encode(_ token: Data) -> String {
        String(decoding: token, as: UTF8.self)
    }
}

/// `PaymentService` backed by the real Sunbay checkout API.
///
/// Ambiguous failures (transport errors, 5xx, unparsable or undecodable bodies) always surface as
/// `.network` `CheckoutError`s so the controller does not treat them as definite rejections.
/// Request and response bodies and secrets never appear in errors or logs.
final class HTTPPaymentService: PaymentService, PaymentActionProviding, @unchecked Sendable {
    private let client: SunbayAPIClient
    private let credentials: CredentialStore
    private let deviceInfo: @Sendable () -> UserDeviceInfoWire?
    private let lock = NSLock()
    private var lastAction: PaymentAction?

    init(client: SunbayAPIClient, credentials: CredentialStore,
         deviceInfo: @escaping @Sendable () -> UserDeviceInfoWire?) {
        self.client = client
        self.credentials = credentials
        self.deviceInfo = deviceInfo
    }

    // MARK: - Wire bodies

    private struct LoadBody: Encodable, Sendable { let checkoutClientSecret: String }
    private struct EmptyBody: Encodable, Sendable {}

    private struct SubmitBody: Encodable, Sendable {
        let sessionId: String
        let paymentMethod: String
        let cardEncryptedData: String?
        let storeCard: Bool?
        let savedCardId: String?
        let customerAccessSecret: String?
        let checkoutClientSecret: String?
        let userDeviceInfo: UserDeviceInfoWire?
    }

    // MARK: - PaymentService

    func loadSession(_ id: String) async throws -> CheckoutSession {
        guard let secret = await credentials.currentCheckoutClientSecret() else {
            throw CheckoutError(code: "CHECKOUT_CLIENT_SECRET_MISSING",
                                message: "The checkout client secret is missing.",
                                category: .configuration, traceId: nil)
        }
        let wire: ContractDecoding.SessionWire = try await client.post(
            .loadSession(id: id), body: LoadBody(checkoutClientSecret: secret))
        do {
            return try wire.toSession()
        } catch {
            throw Self.invalidResponse()
        }
    }

    func submit(_ req: SubmitRequest) async throws -> PaymentSnapshot {
        setAction(nil)
        var cipher = req.cardEncryptedData
        if let token = req.walletToken { cipher = WalletTokenEncoder.encode(token) }
        var secret = req.checkoutClientSecret
        if secret == nil { secret = await credentials.currentCheckoutClientSecret() }
        let body = SubmitBody(
            sessionId: req.sessionId, paymentMethod: req.paymentMethod, cardEncryptedData: cipher,
            storeCard: req.storeCard, savedCardId: req.savedCardId,
            customerAccessSecret: req.customerAccessSecret, checkoutClientSecret: secret,
            userDeviceInfo: deviceInfo())
        let wire: ContractDecoding.ResultWire = try await client.post(
            .submitPayment, body: body, timeout: 30)
        return try accept(wire)
    }

    func getResult(sessionId: String) async throws -> PaymentSnapshot {
        let wire: ContractDecoding.ResultWire = try await client.post(
            .paymentResult(sessionId: sessionId), body: EmptyBody())
        return try accept(wire)
    }

    // MARK: - PaymentActionProviding

    func actionForLatestRequiresAction() -> PaymentAction? {
        lock.lock()
        defer { lock.unlock() }
        return lastAction
    }

    // MARK: - Helpers

    private func accept(_ wire: ContractDecoding.ResultWire) throws -> PaymentSnapshot {
        let envelope: ResultEnvelope
        do {
            envelope = try wire.toEnvelope()
        } catch {
            throw Self.invalidResponse()
        }
        setAction(envelope.action)
        return envelope.snapshot
    }

    private func setAction(_ action: PaymentAction?) {
        lock.lock()
        lastAction = action
        lock.unlock()
    }

    private static func invalidResponse() -> CheckoutError {
        CheckoutError(code: "INVALID_RESPONSE", message: "The server response could not be processed.",
                      category: .network, traceId: nil)
    }
}
