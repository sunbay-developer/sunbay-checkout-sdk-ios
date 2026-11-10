import Foundation

/// Encodes an Apple Pay token for the `cardEncryptedData` field. The wire format for wallet tokens
/// is still an open question; keeping it in one function means a change touches only this place.
enum WalletTokenEncoder {
    /// Returns the token JSON as a UTF-8 string.
    static func encode(_ token: Data) -> String {
        String(decoding: token, as: UTF8.self)
    }
}

/// Wire `AddressInfo`. Whitespace-trimmed; empty values are omitted (keys encode only when present).
struct AddressInfoWire: Encodable, Sendable {
    let country: String?
    let state: String?
    let city: String?
    let address: String?
    let address2: String?
    let postalCode: String?
    let firstName: String?
    let lastName: String?
    let phone: String?
    let email: String?

    /// Maps an `AddressInput` to the wire shape; nil when `input` is nil or has no non-empty field.
    /// `district` is intentionally not sent.
    static func make(_ input: AddressInput?) -> AddressInfoWire? {
        guard let input else { return nil }
        func clean(_ value: String?) -> String? {
            guard let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !trimmed.isEmpty else { return nil }
            return trimmed
        }
        let wire = AddressInfoWire(
            country: clean(input.country), state: clean(input.state), city: clean(input.city),
            address: clean(input.line1), address2: clean(input.line2),
            postalCode: clean(input.postalCode), firstName: clean(input.firstName),
            lastName: clean(input.lastName), phone: clean(input.phone), email: clean(input.email))
        let all = [wire.country, wire.state, wire.city, wire.address, wire.address2,
                   wire.postalCode, wire.firstName, wire.lastName, wire.phone, wire.email]
        return all.contains { $0 != nil } ? wire : nil
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
        let sessionType: String?
        let paymentMethod: String
        let cardEncryptedData: String?
        let storeCard: Bool?
        let savedCardId: String?
        let customerAccessSecret: String?
        let checkoutClientSecret: String?
        let userDeviceInfo: UserDeviceInfoWire?
        let payerBillingInfo: AddressInfoWire?
        let payerShippingAddress: AddressInfoWire?
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
            sessionId: req.sessionId, sessionType: req.sessionType, paymentMethod: req.paymentMethod, cardEncryptedData: cipher,
            storeCard: req.storeCard, savedCardId: req.savedCardId,
            customerAccessSecret: req.customerAccessSecret, checkoutClientSecret: secret,
            userDeviceInfo: deviceInfo(),
            payerBillingInfo: AddressInfoWire.make(req.billingAddress),
            payerShippingAddress: AddressInfoWire.make(req.shippingAddress))
        let wire: ContractDecoding.ResultWire = try await client.post(
            .submitPayment, body: body, timeout: 30)
        return try accept(wire, fallbackSessionId: req.sessionId)
    }

    func getResult(sessionId: String) async throws -> PaymentSnapshot {
        let wire: ContractDecoding.ResultWire = try await client.post(
            .paymentResult(sessionId: sessionId), body: EmptyBody())
        return try accept(wire, fallbackSessionId: sessionId)
    }

    // MARK: - PaymentActionProviding

    func actionForLatestRequiresAction() -> PaymentAction? {
        lock.lock()
        defer { lock.unlock() }
        return lastAction
    }

    // MARK: - Helpers

    private func accept(_ wire: ContractDecoding.ResultWire, fallbackSessionId: String) throws -> PaymentSnapshot {
        let envelope: ResultEnvelope
        do {
            envelope = try wire.toEnvelope(fallbackSessionId: fallbackSessionId)
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
