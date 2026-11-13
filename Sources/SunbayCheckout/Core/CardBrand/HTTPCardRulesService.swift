import Foundation

/// A `CardRulesService` backed by `GET /api/card/rules` on the HPP server, reached through
/// `SunbayAPIClient` (environment host).
///
/// The endpoint returns the raw rules document (no envelope) with an `ETag`. The stored `ETag` is sent
/// back byte-for-byte as `If-None-Match`; `304` means the stored copy is current. The client session
/// has no URL cache, so a `304` is never answered (and hidden) by the system. Any other status, or a
/// transport failure, throws; the refresher then keeps the current rules.
///
/// - Note: UI-agnostic (Foundation only). The document is public data; nothing sensitive is sent.
struct HTTPCardRulesService: CardRulesService {
    private let client: SunbayAPIClient

    init(client: SunbayAPIClient) {
        self.client = client
    }

    func fetchRules(ifNoneMatch etag: String?) async throws -> CardRulesFetchResult {
        let headers = etag.map { ["If-None-Match": $0] } ?? [:]
        let (data, response) = try await client.getRaw(.cardRules, headers: headers)
        switch response.statusCode {
        case 304:
            return .notModified
        case 200:
            return .updated(data, etag: response.value(forHTTPHeaderField: "ETag"))
        default:
            throw CheckoutError(
                code: "HTTP_\(response.statusCode)", message: "The server returned an HTTP error.",
                category: .network, traceId: nil)
        }
    }
}
