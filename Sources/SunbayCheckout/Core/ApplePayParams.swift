import Foundation

/// The Apple Pay request parameters the backend delivers in `ewalletParam` of the `APPLE_PAY` payment method.
///
/// Only `countryCode`, `supportedNetworks` and `merchantCapabilities` are read; every other key is ignored.
/// Parsing is tolerant: wrong types and non-string elements are dropped instead of failing the session.
/// Foundation only (no PassKit); the PassKit mapping lives in `UI/Wallet`.
struct ApplePayParams: Equatable, Sendable, Decodable {
    var countryCode: String?
    var supportedNetworks: [String]
    var merchantCapabilities: [String]

    init(countryCode: String?, supportedNetworks: [String], merchantCapabilities: [String]) {
        self.countryCode = countryCode
        self.supportedNetworks = supportedNetworks
        self.merchantCapabilities = merchantCapabilities
    }

    private enum CodingKeys: String, CodingKey {
        case countryCode, supportedNetworks, merchantCapabilities
    }

    /// Decodes tolerantly; throws only when the value is not a JSON object.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        countryCode = try? c.decodeIfPresent(String.self, forKey: .countryCode)
        supportedNetworks = (try? c.decode(LossyStrings.self, forKey: .supportedNetworks))?.values ?? []
        merchantCapabilities = (try? c.decode(LossyStrings.self, forKey: .merchantCapabilities))?.values ?? []
    }

    /// Parses the JSON of the `ewalletParam` object. nil / invalid JSON / not an object → nil.
    static func parse(_ raw: Data?) -> ApplePayParams? {
        guard let raw else { return nil }
        return try? JSONDecoder().decode(ApplePayParams.self, from: raw)
    }

    /// An array of strings that drops non-string elements.
    private struct LossyStrings: Decodable {
        let values: [String]

        private struct Skip: Decodable {}

        init(from decoder: Decoder) throws {
            var c = try decoder.unkeyedContainer()
            var out: [String] = []
            while !c.isAtEnd {
                if let s = try? c.decode(String.self) {
                    out.append(s)
                } else {
                    _ = try? c.decode(Skip.self) // advance past the unreadable element
                }
            }
            values = out
        }
    }
}
