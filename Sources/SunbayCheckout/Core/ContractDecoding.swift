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

    /// The wire format of the session `data` object (only takes the fields Core needs; other fields are ignored).
    struct SessionWire: Decodable {
        let sessionId: String
        let currency: String
        /// Total amount in integer minor currency units.
        let totalAmount: Int64
        let expiresAt: String
        let merchantName: String
        let rsaPublicKey: String?
        /// Backend `supportStoreCard`; absent means `true`.
        let supportStoreCard: Bool
        let paymentMethods: [PaymentMethodWire]

        private enum CodingKeys: String, CodingKey {
            case sessionId, currency, totalAmount, expiresAt, merchantName
            case rsaPublicKey, supportStoreCard, paymentMethods
        }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            sessionId = try c.decode(String.self, forKey: .sessionId)
            currency = try c.decode(String.self, forKey: .currency)
            // Decode as Decimal and require an integral value so 10.5 is rejected instead of truncated.
            let amount = try c.decode(Decimal.self, forKey: .totalAmount)
            guard let minor = ContractDecoding.integralInt64(amount) else {
                throw DecodingError.dataCorruptedError(
                    forKey: .totalAmount,
                    in: c,
                    debugDescription: "totalAmount must be an integral number of minor units"
                )
            }
            totalAmount = minor
            expiresAt = try c.decode(String.self, forKey: .expiresAt)
            merchantName = try c.decode(String.self, forKey: .merchantName)
            rsaPublicKey = try c.decodeIfPresent(String.self, forKey: .rsaPublicKey)
            supportStoreCard = try c.decodeIfPresent(Bool.self, forKey: .supportStoreCard) ?? true
            paymentMethods = try c.decode([PaymentMethodWire].self, forKey: .paymentMethods)
        }

        /// Converts the wire object into a `CheckoutSession`.
        ///
        /// - Throws: `DecodingError` when `expiresAt` is not a valid ISO-8601 date.
        func toSession() throws -> CheckoutSession {
            guard let expiresAt = ContractDecoding.parseISO8601(expiresAt) else {
                throw DecodingError.dataCorrupted(
                    DecodingError.Context(
                        codingPath: [],
                        debugDescription: "expiresAt is not a valid ISO-8601: \(expiresAt)"
                    )
                )
            }

            // Unknown method: ignored (downgrade), does not crash.
            let methods = paymentMethods.reduce(into: Set<PaymentMethodKind>()) { acc, pm in
                if let kind = ContractDecoding.mapMethod(method: pm.method, type: pm.type) {
                    acc.insert(kind)
                }
            }

            return CheckoutSession(
                id: sessionId,
                amount: Amount(minorUnits: totalAmount, currencyCode: currency),
                merchantName: merchantName,
                methods: methods,
                expiresAt: expiresAt,
                rsaPublicKey: rsaPublicKey,
                cofEnabled: supportStoreCard
            )
        }
    }

    /// A single payment method entry (§7.1: `method` e.g. VISA/APPLE_PAY, `type` e.g. CARD/E_WALLET).
    struct PaymentMethodWire: Decodable {
        let method: String
        let type: String
    }

    /// Decodes the session JSON into a `CheckoutSession`.
    ///
    /// - Parameter data: The session JSON data.
    /// - Returns: The decoded session model.
    /// - Throws: Throws `DecodingError` when the JSON structure does not match or `expiresAt` is not valid ISO-8601.
    static func decodeSession(from data: Data) throws -> CheckoutSession {
        try JSONDecoder().decode(SessionWire.self, from: data).toSession()
    }

    /// Converts a `Decimal` to `Int64` when it is integral and in range; otherwise nil.
    fileprivate static func integralInt64(_ value: Decimal) -> Int64? {
        var source = value
        var rounded = Decimal()
        NSDecimalRound(&rounded, &source, 0, .plain)
        guard rounded == value else { return nil }
        let number = NSDecimalNumber(decimal: rounded)
        guard number.compare(NSDecimalNumber(value: Int64.max)) != .orderedDescending,
            number.compare(NSDecimalNumber(value: Int64.min)) != .orderedAscending
        else { return nil }
        return number.int64Value
    }

    /// Maps the backend `method`/`type` to a `PaymentMethodKind`.
    ///
    /// A known card brand or `type == "CARD"` → `.card`; `APPLE_PAY` → `.applePay`; everything else returns nil (ignored).
    ///
    /// - Note: The available methods issued in the session describe new card / wallet; the availability of `.savedCard` is determined by `cofEnabled` and
    ///   the card listing result (§7.5), not derived from the method entries here.
    fileprivate static func mapMethod(method: String, type: String) -> PaymentMethodKind? {
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

    /// The wire format of the submit / result `data` object.
    struct ResultWire: Decodable {
        let txnId: String?
        let txnStatus: String
        let sessionId: String
        let action: ActionWire?
    }

    /// The `action` object (§7.4; carried when `txnStatus == "R"`).
    struct ActionWire: Decodable {
        let type: String
        let redirectUrl: String?
    }

    /// Decodes the result JSON into a `ResultEnvelope` (snapshot + optional action).
    ///
    /// - Parameter data: The result JSON data.
    /// - Returns: The decoded result envelope.
    /// - Throws: Throws `DecodingError` when the JSON structure does not match or `txnStatus` is invalid.
    static func decodeResult(from data: Data) throws -> ResultEnvelope {
        try JSONDecoder().decode(ResultWire.self, from: data).toEnvelope()
    }

    /// Maps the `action` object to a `PaymentAction`; downgrades to `.unknown` when unrecognized.
    fileprivate static func mapAction(_ action: ActionWire?) -> PaymentAction {
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

    /// Parses an ISO-8601 string into a `Date`.
    ///
    /// Supports offsets with and without a colon (`+08:00` / `+0800`), with and without fractional seconds.
    fileprivate static func parseISO8601(_ string: String) -> Date? {
        let withFractional = ISO8601DateFormatter()
        withFractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = withFractional.date(from: string) {
            return date
        }
        let plain = ISO8601DateFormatter()
        plain.formatOptions = [.withInternetDateTime]
        if let date = plain.date(from: string) {
            return date
        }
        // Fallback for offsets without a colon, which ISO8601DateFormatter rejects.
        for format in ["yyyy-MM-dd'T'HH:mm:ssZ", "yyyy-MM-dd'T'HH:mm:ss.SSSZ"] {
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.dateFormat = format
            if let date = formatter.date(from: string) {
                return date
            }
        }
        return nil
    }
}

extension ContractDecoding.ResultWire {
    /// Converts the wire object into a `ResultEnvelope`.
    ///
    /// `txnStatus` maps to `TxnStatus` (I/S/F/R); when `R`, `action` is mapped by type:
    /// `redirect` with a valid `redirectUrl` → `.redirect(url:)`, otherwise `.unknown`;
    /// `qrCode` → `.qrCode`; `showContent` → `.showContent`; everything else → `.unknown`.
    ///
    /// - Throws: `DecodingError` when `txnStatus` is not recognized.
    func toEnvelope() throws -> ResultEnvelope {
        guard let status = TxnStatus(rawValue: txnStatus) else {
            throw DecodingError.dataCorrupted(
                DecodingError.Context(
                    codingPath: [],
                    debugDescription: "Unknown txnStatus: \(txnStatus)"
                )
            )
        }
        let snapshot = PaymentSnapshot(sessionId: sessionId, status: status, txnId: txnId)
        let mapped: PaymentAction? = status == .requiresAction ? ContractDecoding.mapAction(action) : nil
        return ResultEnvelope(snapshot: snapshot, action: mapped)
    }
}
