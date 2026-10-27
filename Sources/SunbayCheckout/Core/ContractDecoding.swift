import Foundation

/// The decoding product of a result query: a snapshot plus an optional further action.
///
/// `PaymentSnapshot` keeps the Task 2 definition unchanged (no added fields); `action` is parsed when `txnStatus == "R"`,
/// for Task 6/8 to dispatch by type (see §4.5).
struct ResultEnvelope: Sendable, Equatable {
    /// The result snapshot.
    let snapshot: PaymentSnapshot
    /// The further action; nil when not `requiresAction` or when there is no `action`.
    let action: PaymentAction?
}

/// Decoding helper (internal) from backend contract JSON to Core models.
///
/// Maps the session JSON of product-spec §7.1 and the result JSON of §7.4 to `CheckoutSession` /
/// `PaymentSnapshot` / `PaymentAction`. Downgrades unknown payment methods and action types without crashing.
///
/// - Note: This is pure decoding logic and does not touch the network; the real adapter is responsible for feeding the response body to these functions.
enum ContractDecoding {
    // MARK: - Session (§7.1)

    /// The wire format of the session JSON (only takes the fields Core needs; other fields are ignored).
    private struct SessionWire: Decodable {
        let sessionId: String
        let currency: String
        let totalAmount: Int64
        let expiresAt: String
        let merchantName: String
        let rsaPublicKey: String?
        let cofEnabled: Bool
        let paymentMethods: [PaymentMethodWire]
    }

    /// A single payment method entry (§7.1: `method` e.g. VISA/APPLE_PAY, `type` e.g. CARD/E_WALLET).
    private struct PaymentMethodWire: Decodable {
        let method: String
        let type: String
    }

    /// Decodes the session JSON into a `CheckoutSession`.
    ///
    /// - `totalAmount` + `currency` → `Amount(minorUnits:currencyCode:)` (integer minor currency units).
    /// - `paymentMethods[].method/type` → `Set<PaymentMethodKind>`; unknown methods are ignored rather than crashing.
    /// - `expiresAt` is parsed as ISO-8601.
    ///
    /// - Parameter data: The session JSON data.
    /// - Returns: The decoded session model.
    /// - Throws: Throws `DecodingError` when the JSON structure does not match or `expiresAt` is not valid ISO-8601.
    static func decodeSession(from data: Data) throws -> CheckoutSession {
        let wire = try JSONDecoder().decode(SessionWire.self, from: data)

        guard let expiresAt = parseISO8601(wire.expiresAt) else {
            throw DecodingError.dataCorrupted(
                DecodingError.Context(
                    codingPath: [],
                    debugDescription: "expiresAt is not a valid ISO-8601: \(wire.expiresAt)"
                )
            )
        }

        let methods = wire.paymentMethods.reduce(into: Set<PaymentMethodKind>()) { acc, pm in
            if let kind = mapMethod(method: pm.method, type: pm.type) {
                acc.insert(kind)
            }
            // Unknown method: ignored (downgrade), does not crash.
        }

        return CheckoutSession(
            id: wire.sessionId,
            amount: Amount(minorUnits: wire.totalAmount, currencyCode: wire.currency),
            merchantName: wire.merchantName,
            methods: methods,
            expiresAt: expiresAt,
            rsaPublicKey: wire.rsaPublicKey,
            cofEnabled: wire.cofEnabled
        )
    }

    /// Maps the backend `method`/`type` to a `PaymentMethodKind`.
    ///
    /// A known card brand or `type == "CARD"` → `.card`; `APPLE_PAY` → `.applePay`; everything else returns nil (ignored).
    ///
    /// - Note: The available methods issued in the session describe new card / wallet; the availability of `.savedCard` is determined by `cofEnabled` and
    ///   the card listing result (§7.5), not derived from the method entries here.
    private static func mapMethod(method: String, type: String) -> PaymentMethodKind? {
        switch method.uppercased() {
        case "APPLE_PAY":
            return .applePay
        case "VISA", "MASTERCARD", "AMEX", "CARD":
            return .card
        default:
            // Fall back to type: an explicit CARD is also treated as a new card.
            return type.uppercased() == "CARD" ? .card : nil
        }
    }

    // MARK: - Result (§7.4)

    /// The wire format of the result JSON.
    private struct ResultWire: Decodable {
        let txnId: String?
        let txnStatus: String
        let sessionId: String
        let action: ActionWire?
    }

    /// The `action` object (§7.4; carried when `txnStatus == "R"`).
    private struct ActionWire: Decodable {
        let type: String
        let redirectUrl: String?
    }

    /// Decodes the result JSON into a `ResultEnvelope` (snapshot + optional action).
    ///
    /// `txnStatus` maps to `TxnStatus` (I/S/F/R); when `txnStatus == "R"`, parses `action.type`:
    /// `redirect` with a valid `redirectUrl` → `.redirect(url:)`, otherwise `.unknown`;
    /// `qrCode` → `.qrCode`; `showContent` → `.showContent`; everything else → `.unknown`.
    ///
    /// - Parameter data: The result JSON data.
    /// - Returns: The decoded result envelope.
    /// - Throws: Throws `DecodingError` when the JSON structure does not match or `txnStatus` is invalid.
    static func decodeResult(from data: Data) throws -> ResultEnvelope {
        let wire = try JSONDecoder().decode(ResultWire.self, from: data)

        guard let status = TxnStatus(rawValue: wire.txnStatus) else {
            throw DecodingError.dataCorrupted(
                DecodingError.Context(
                    codingPath: [],
                    debugDescription: "Unknown txnStatus: \(wire.txnStatus)"
                )
            )
        }

        let snapshot = PaymentSnapshot(
            sessionId: wire.sessionId,
            status: status,
            txnId: wire.txnId
        )

        let action: PaymentAction? = status == .requiresAction ? mapAction(wire.action) : nil
        return ResultEnvelope(snapshot: snapshot, action: action)
    }

    /// Maps the `action` object to a `PaymentAction`; downgrades to `.unknown` when unrecognized.
    private static func mapAction(_ action: ActionWire?) -> PaymentAction {
        guard let action else { return .unknown }
        switch action.type {
        case "redirect":
            // redirect requires a valid URL; if missing or invalid, a redirect is impossible, so downgrade to unknown.
            if let raw = action.redirectUrl, let url = URL(string: raw) {
                return .redirect(url: url)
            }
            return .unknown
        case "qrCode":
            return .qrCode
        case "showContent":
            return .showContent
        default:
            return .unknown
        }
    }

    // MARK: - ISO-8601

    /// Parses an ISO-8601 string into a `Date`; supports both with and without fractional seconds.
    private static func parseISO8601(_ string: String) -> Date? {
        let withFractional = ISO8601DateFormatter()
        withFractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = withFractional.date(from: string) {
            return date
        }
        let plain = ISO8601DateFormatter()
        plain.formatOptions = [.withInternetDateTime]
        return plain.date(from: string)
    }
}
