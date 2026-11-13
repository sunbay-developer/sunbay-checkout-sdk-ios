import Foundation

/// Persists the last valid remote rules document in the OS cache directory.
///
/// The document is public, non-sensitive data (card-brand formats), so it may be stored. It lives in
/// `Caches` (purgeable); losing it only means falling back to the bundled rules.
struct CardRulesStore {
    private let directory: URL

    /// - Parameter directory: Override for tests; defaults to `Caches/com.sunbay.checkout`.
    init(directory: URL? = nil) {
        self.directory =
            directory
            ?? FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first!
            .appendingPathComponent("com.sunbay.checkout", isDirectory: true)
    }

    private var documentURL: URL { directory.appendingPathComponent("card-rules.json") }
    private var etagURL: URL { directory.appendingPathComponent("card-rules.etag") }

    /// The stored, validated document, or nil.
    func load() -> CardRuleSet? {
        guard let data = try? Data(contentsOf: documentURL) else { return nil }
        return CardRuleSet.parse(data)
    }

    /// The stored `ETag`, only if a valid document is stored with it.
    func etag() -> String? {
        guard load() != nil else { return nil }
        return (try? String(contentsOf: etagURL, encoding: .utf8))
    }

    /// Stores a document that has already been validated.
    func save(data: Data, etag: String?) {
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try? data.write(to: documentURL, options: .atomic)
        if let etag { try? etag.write(to: etagURL, atomically: true, encoding: .utf8) } else {
            try? FileManager.default.removeItem(at: etagURL)
        }
    }
}

/// Supplies the rules in effect: cached remote > bundled > a minimal built-in generic set.
enum CardRulesProvider {
    /// The rules to use for a card component shown now.
    static func activeRuleSet(store: CardRulesStore = CardRulesStore()) -> CardRuleSet {
        store.load() ?? bundled ?? minimal
    }

    /// The copy shipped inside the SDK (overwritten from the live endpoint at release time).
    static let bundled: CardRuleSet? = {
        guard let url = Bundle.module.url(forResource: "card-brand-rules", withExtension: "json"),
            let data = try? Data(contentsOf: url)
        else { return nil }
        return CardRuleSet.parse(data)
    }()

    /// Last resort if even the bundled copy cannot be read: no brands, generic behavior.
    static let minimal = CardRuleSet(
        schemaVersion: CardRuleSet.supportedSchemaVersion, version: "minimal",
        generic: .init(
            groups: [4, 4, 4, 4], minLength: 12, maxLength: 19,
            cvv: .init(name: "CVC", sizes: [3, 4])),
        brands: [])
}

/// Limits how often the rules are checked: one claim per `minInterval`, thread-safe.
///
/// A failed or `304` check also consumes the claim, so an unhealthy server is not hammered.
final class CardRulesRefreshGate: @unchecked Sendable {
    /// The gate shared by the whole process.
    static let shared = CardRulesRefreshGate()

    private let minInterval: TimeInterval
    private let lock = NSLock()
    private var lastClaim: Date?

    /// - Parameter minInterval: Seconds between allowed checks (one hour by default).
    init(minInterval: TimeInterval = 3600) {
        self.minInterval = minInterval
    }

    /// Returns true (and records `now`) when no claim happened within the interval.
    func claim(now: Date = Date()) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        if let lastClaim, now.timeIntervalSince(lastClaim) < minInterval { return false }
        lastClaim = now
        return true
    }
}

/// Refreshes the cached rules in the background. Applies at the **next** time a card component is
/// shown; it never changes the rules of a component already on screen.
enum CardRulesRefresher {
    /// Fire-and-forget conditional refresh, at most once per gate interval (one hour per process by
    /// default). Failures and invalid documents are ignored silently.
    static func refreshInBackground(
        service: any CardRulesService, store: CardRulesStore = CardRulesStore(),
        gate: CardRulesRefreshGate = .shared
    ) {
        guard gate.claim() else { return }
        Task.detached(priority: .utility) {
            await refresh(service: service, store: store)
        }
    }

    /// One conditional refresh (internal for tests). Keeps the previous rules on any problem.
    static func refresh(service: any CardRulesService, store: CardRulesStore) async {
        guard let result = try? await service.fetchRules(ifNoneMatch: store.etag()) else { return }
        guard case .updated(let data, let etag) = result, CardRuleSet.parse(data) != nil else { return }
        store.save(data: data, etag: etag)
    }
}
