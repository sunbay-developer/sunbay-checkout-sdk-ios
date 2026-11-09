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
        /// Total amount converted from the wire major-unit value to integer minor currency units.
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
            totalAmount = try ContractDecoding.decodeMinorUnits(
                from: c, forKey: .totalAmount, currencyCode: currency)
            expiresAt = try c.decode(String.self, forKey: .expiresAt)
            merchantName = try c.decode(String.self, forKey: .merchantName)
            rsaPublicKey = try c.decodeIfPresent(String.self, forKey: .rsaPublicKey)
            supportStoreCard = try c.decodeIfPresent(Bool.self, forKey: .supportStoreCard) ?? true
            paymentMethods = try c.decode([PaymentMethodWire].self, forKey: .paymentMethods)
        }

        /// Converts the wire object into a `CheckoutSession`.
        ///
        /// - Throws: `DecodingError` when `expiresAt` is not in a supported timestamp format (see `parseISO8601`).
        func toSession() throws -> CheckoutSession {
            guard let expiresAt = ContractDecoding.parseISO8601(expiresAt) else {
                throw DecodingError.dataCorrupted(
                    DecodingError.Context(
                        codingPath: [],
                        debugDescription: "expiresAt is not in a supported timestamp format: \(expiresAt)"
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
    /// - Throws: Throws `DecodingError` when the JSON structure does not match `expiresAt` is not a supported timestamp format, or the currency is unknown/malformed.
    static func decodeSession(from data: Data) throws -> CheckoutSession {
        try JSONDecoder().decode(SessionWire.self, from: data).toSession()
    }

    /// Reads a major-unit amount (JSON string or number) and converts it to minor units.
    ///
    /// The currency must be 3 ASCII letters known to Foundation, otherwise the session is rejected (no silent 2-digit fallback).
    /// The number of fraction digits comes from Foundation's ISO 4217 data via `NumberFormatter`.
    /// Parsing uses `Decimal` only, so there is no binary rounding.
    fileprivate static func decodeMinorUnits<K: CodingKey>(
        from container: KeyedDecodingContainer<K>, forKey key: K, currencyCode: String
    ) throws -> Int64 {
        func corrupted(_ reason: String) -> DecodingError {
            DecodingError.dataCorruptedError(forKey: key, in: container, debugDescription: reason)
        }
        let major: Decimal
        if let text = try? container.decode(String.self, forKey: key) {
            guard isPlainDecimal(text), let parsed = Decimal(string: text, locale: Locale(identifier: "en_US_POSIX"))
            else { throw corrupted("totalAmount is not a numeric major-unit amount") }
            major = parsed
        } else if let number = try? container.decode(Decimal.self, forKey: key) {
            major = number
        } else {
            throw corrupted("totalAmount must be a string or number in major units")
        }
        guard major >= 0 else { throw corrupted("totalAmount must not be negative") }

        guard isKnownCurrency(currencyCode) else {
            throw corrupted("currency must be a known ISO 4217 code of 3 ASCII letters")
        }
        let digits = fractionDigits(currencyCode: currencyCode)
        var scaled = major
        var base = Decimal(1)
        for _ in 0..<digits { base *= 10 }
        scaled *= base
        var rounded = Decimal()
        NSDecimalRound(&rounded, &scaled, 0, .plain)
        guard rounded == scaled else {
            throw corrupted("totalAmount has more fraction digits than \(currencyCode) allows (\(digits))")
        }
        let number = NSDecimalNumber(decimal: rounded)
        guard number.compare(NSDecimalNumber(value: Int64.max)) != .orderedDescending else {
            throw corrupted("totalAmount overflows")
        }
        return number.int64Value
    }

    /// True for `digits[.digits]` with an optional leading `-` (no spaces, exponent, or separators).
    private static func isPlainDecimal(_ text: String) -> Bool {
        let body = text.hasPrefix("-") ? String(text.dropFirst()) : text
        let parts = body.split(separator: ".", maxSplits: 1, omittingEmptySubsequences: false)
        guard !parts.isEmpty, parts.count <= 2 else { return false }
        let isDigits = { (p: Substring) in !p.isEmpty && p.allSatisfy { $0 >= "0" && $0 <= "9" } }
        return parts.allSatisfy(isDigits)
    }

    /// True when the code is exactly 3 ASCII letters and known to Foundation (case-insensitive).
    private static func isKnownCurrency(_ code: String) -> Bool {
        guard code.utf8.count == 3, code.utf8.allSatisfy({ ($0 >= 65 && $0 <= 90) || ($0 >= 97 && $0 <= 122) })
        else { return false }
        let upper = code.uppercased()
        // `Locale.isoCurrencyCodes` is deprecated on newer OSes but available on the SDK's minimum target.
        if #available(macOS 13, iOS 16, *) {
            return Locale.commonISOCurrencyCodes.contains(upper)
        }
        return Locale.isoCurrencyCodes.contains(upper)
    }

    /// ISO 4217 minor-unit digits for a currency, from Foundation (`NumberFormatter`).
    private static func fractionDigits(currencyCode: String) -> Int {
        let formatter = NumberFormatter()
        formatter.numberStyle = .currency
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.currencyCode = currencyCode.uppercased()
        return formatter.maximumFractionDigits
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

    // MARK: - Date parsing

    // Formatters are configured exactly once (static let initializer, thread-safe by Swift's lazy
    // static semantics) and only read afterwards via `date(from:)`, which is documented as safe
    // for concurrent use on modern Foundation; nothing mutates them after configuration.
    private static let isoFractional: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    private static let isoPlain: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()

    private static func makeFormatter(_ format: String, utc: Bool) -> DateFormatter {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        if utc { f.timeZone = TimeZone(secondsFromGMT: 0) }
        f.dateFormat = format
        return f
    }

    /// Offsets without a colon (`+0800`), which `ISO8601DateFormatter` rejects.
    private static let noColonOffsetFormatters: [DateFormatter] = [
        makeFormatter("yyyy-MM-dd'T'HH:mm:ssZ", utc: false),
        makeFormatter("yyyy-MM-dd'T'HH:mm:ss.SSSZ", utc: false),
    ]

    /// The backend's zone-less format, which is UTC (ruling R6).
    private static let zonelessUTCFormatters: [DateFormatter] = [
        makeFormatter("yyyy-MM-dd HH:mm:ss", utc: true),
        makeFormatter("yyyy-MM-dd HH:mm:ss.SSS", utc: true),
    ]

    /// Parses a backend timestamp into a `Date`.
    ///
    /// Accepts ISO-8601 with an offset (with/without colon, with/without fractional seconds) and the
    /// zone-less `yyyy-MM-dd HH:mm:ss[.SSS]` form, interpreted as UTC.
    fileprivate static func parseISO8601(_ string: String) -> Date? {
        if let date = isoFractional.date(from: string) { return date }
        if let date = isoPlain.date(from: string) { return date }
        for formatter in noColonOffsetFormatters {
            if let date = formatter.date(from: string) { return date }
        }
        // DateFormatter tolerates mismatched separators (e.g. "2026/11/09"), so check the shape first.
        let shape = #"^\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2}(\.\d{3})?$"#
        guard string.range(of: shape, options: .regularExpression) != nil else { return nil }
        for formatter in zonelessUTCFormatters {
            if let date = formatter.date(from: string) { return date }
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
