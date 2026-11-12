import Foundation

/// Wire shape of one `CardItem` from `card/list`. Every field is optional so a single malformed
/// item can be dropped without failing the whole response.
struct CardItemWire: Decodable, Sendable {
    let savedCardId: String?
    let maskedCardNumber: String?
    let cardBrand: String?
    let expiryMonth: String?
    let expiryYear: String?
    let logoUrl: String?
}

/// Wire shape of the `card/list` `data` object. A missing `cards` decodes as an empty list.
struct CardListWire: Decodable, Sendable {
    let cards: [CardItemWire]

    private enum CodingKeys: String, CodingKey { case cards }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        cards = (try container.decodeIfPresent([Lossy].self, forKey: .cards) ?? []).compactMap(\.value)
    }

    /// Decodes an element, yielding nil instead of throwing when it is not a valid object.
    private struct Lossy: Decodable {
        let value: CardItemWire?
        init(from decoder: Decoder) throws {
            value = try? CardItemWire(from: decoder)
        }
    }
}

/// `CofService` backed by the real Sunbay `card/list` endpoint.
///
/// Whatever `SunbayAPIClient` throws is rethrown unchanged (it never contains the secret or any
/// body); the controller degrades every failure to "no saved cards". A success envelope with no
/// `data` at all is reported by the client as `INVALID_RESPONSE` (also degraded); `data: {}` and
/// `data: {"cards": []}` both yield an empty list.
struct HTTPCofService: CofService {
    private let client: SunbayAPIClient

    init(client: SunbayAPIClient) {
        self.client = client
    }

    private struct ListBody: Encodable, Sendable {
        let sessionId: String
        let customerAccessSecret: String
    }

    func listPaymentMethods(customerAccessSecret: String, sessionId: String) async throws -> [SavedCard] {
        let wire: CardListWire = try await client.post(
            .cardList,
            body: ListBody(sessionId: sessionId, customerAccessSecret: customerAccessSecret))
        return wire.cards.compactMap(Self.map)
    }

    /// Deleting a saved card is not available yet: the backend endpoint has not been provided.
    /// Makes no request. Tracked in `docs/real-api-integration-checklist.md`.
    func deleteCard(savedCardId: String, customerAccessSecret: String, sessionId: String) async throws {
        throw CheckoutErrors.cardDeleteUnsupported()
    }

    /// Maps a wire item to a `SavedCard`, or nil when any required field is invalid.
    static func map(_ item: CardItemWire) -> SavedCard? {
        guard let id = item.savedCardId, !id.isEmpty,
              let brand = item.cardBrand,
              let masked = item.maskedCardNumber,
              let monthText = item.expiryMonth, let yearText = item.expiryYear else { return nil }
        let digits = masked.unicodeScalars.filter { $0.value >= 0x30 && $0.value <= 0x39 }
        guard digits.count >= 4 else { return nil }
        let last4 = String(String.UnicodeScalarView(digits.suffix(4)))
        guard let month = asciiInt(monthText), (1...12).contains(month),
              let yearValue = asciiInt(yearText) else { return nil }
        let year: Int
        switch yearText.count {
        case 2: year = 2000 + yearValue
        case 4: year = yearValue
        default: return nil
        }
        return SavedCard(id: id, brand: brand.lowercased(), last4: last4, expMonth: month, expYear: year,
                         logoUrl: logoURL(item.logoUrl))
    }

    /// Parses a logo URL; anything that is not a valid http(s) URL is nil (a bad logo never drops the card).
    static func logoURL(_ raw: String?) -> URL? {
        guard let raw = raw?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty,
              let url = URL(string: raw), let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https", url.host != nil else { return nil }
        return url
    }

    private static func asciiInt(_ text: String) -> Int? {
        guard !text.isEmpty, text.unicodeScalars.allSatisfy({ $0.value >= 0x30 && $0.value <= 0x39 }) else {
            return nil
        }
        return Int(text)
    }
}
