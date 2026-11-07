import Foundation

/// The outcome of a conditional rules fetch.
enum CardRulesFetchResult: Sendable {
    /// The server confirmed the stored copy is current (`304`).
    case notModified
    /// A new document (raw bytes) and its `ETag`, if any.
    case updated(Data, etag: String?)
}

/// Fetches the card-brand rules document from the HPP server (`GET /api/card/rules`).
///
/// Internal for now: no real adapter exists yet (see `docs/real-api-integration-checklist.md`). The
/// default is `EmptyCardRulesService`, so the bundled rules are used.
protocol CardRulesService: Sendable {
    /// - Parameter etag: The stored `ETag`, sent as `If-None-Match`; nil on the first fetch.
    func fetchRules(ifNoneMatch etag: String?) async throws -> CardRulesFetchResult
}

/// Recognizes a card scheme from a BIN via the HPP server (`POST /api/card/bin`).
///
/// The BIN (first 6–9 digits) is sensitive: implementations must never log or persist it.
protocol CardBinService: Sendable {
    /// - Returns: The lower-case scheme (matching a rules `scheme` key), or nil when unrecognized.
    func recognize(bin: String, sessionId: String) async throws -> String?
}

/// Fail-soft default: never updates the rules.
struct EmptyCardRulesService: CardRulesService {
    func fetchRules(ifNoneMatch etag: String?) async throws -> CardRulesFetchResult { .notModified }
}

/// Fail-soft default: never recognizes anything (local prefix matching is used).
struct EmptyCardBinService: CardBinService {
    func recognize(bin: String, sessionId: String) async throws -> String? { nil }
}
