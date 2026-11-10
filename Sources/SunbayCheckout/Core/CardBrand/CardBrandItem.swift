import Foundation

/// One card brand the session supports, with the logo the backend provides for it (UI-agnostic).
///
/// Built from the session's `paymentMethods` entries; carries no card data.
struct CardBrandItem: Equatable, Sendable {
    /// Lowercased, trimmed backend method (for example `visa`, `dinersclub`); matches the rule-set scheme keys.
    let scheme: String
    /// Display name from the session (may be empty).
    let name: String
    /// HTTPS logo URL from the session.
    let logoURL: URL

    /// The card brands of a session: `CARD` entries with a valid `https` logo, in backend order, first
    /// occurrence per scheme.
    static func items(from entries: [MethodEntry]) -> [CardBrandItem] {
        var seen: Set<String> = []
        var result: [CardBrandItem] = []
        for entry in entries where entry.type == "CARD" {
            let scheme = normalize(entry.method)
            guard !scheme.isEmpty, !seen.contains(scheme),
                let raw = entry.logoURL, let url = URL(string: raw),
                url.scheme?.lowercased() == "https", url.host?.isEmpty == false
            else { continue }
            seen.insert(scheme)
            result.append(CardBrandItem(scheme: scheme, name: entry.name, logoURL: url))
        }
        return result
    }

    /// The item for a recognized scheme (case-insensitive), or `nil` for a nil / empty / unsupported scheme.
    static func item(matching scheme: String?, in items: [CardBrandItem]) -> CardBrandItem? {
        guard let scheme else { return nil }
        let key = normalize(scheme)
        guard !key.isEmpty else { return nil }
        return items.first { $0.scheme == key }
    }

    private static func normalize(_ raw: String) -> String {
        raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }
}
