import Foundation

/// One payment method entry of a session, in backend order.
struct MethodEntry: Equatable, Sendable {
    /// Raw backend method (for example `VISA`, `APPLE_PAY`).
    let method: String
    /// Backend type (for example `CARD`, `E_WALLET`).
    let type: String
    /// Display name; may be empty.
    let name: String
    /// Logo URL; nil when absent.
    let logoURL: String?
}

/// Pure logic behind `PaymentMethodFilter` (no UI types).
enum PaymentMethodModel {
    /// An identifier that matched nothing, with a reason listing the available identifiers.
    struct FilterIgnored: Equatable {
        let identifier: String
        let reason: String
    }

    /// The logical key of an entry: `CARD` for every `type = CARD` entry, otherwise the raw method.
    static func logicalKey(_ e: MethodEntry) -> String {
        e.type == "CARD" ? "CARD" : e.method
    }

    /// Applies `filter` to `entries`; never fails. Matching uses the original entries, so an id listed in both
    /// `hide` and `order` is hidden without being ignored.
    static func apply(
        _ filter: PaymentMethodFilter, to entries: [MethodEntry]
    ) -> (entries: [MethodEntry], ignored: [FilterIgnored]) {
        func matches(_ entry: MethodEntry, _ id: String) -> Bool {
            logicalKey(entry) == id || entry.method == id
        }
        var available: [String] = []
        for entry in entries {
            for id in [logicalKey(entry), entry.method] where !available.contains(id) { available.append(id) }
        }
        var ignored: [FilterIgnored] = []
        var reported = Set<String>()
        for id in (filter.hide + filter.order).map(\.rawValue)
        where !entries.contains(where: { matches($0, id) }) && reported.insert(id).inserted {
            ignored.append(FilterIgnored(
                identifier: id,
                reason: "No payment method matches \"\(id)\". Available identifiers: \(available.joined(separator: ", "))."))
        }
        let hidden = filter.hide.map(\.rawValue)
        let order = filter.order.map(\.rawValue)
        let kept = entries.filter { entry in !hidden.contains { matches(entry, $0) } }
        func rank(_ entry: MethodEntry) -> Int {
            order.firstIndex { matches(entry, $0) } ?? Int.max
        }
        // Stable: sort indices by (rank, original position).
        let sorted = kept.enumerated().sorted { a, b in
            let (ra, rb) = (rank(a.element), rank(b.element))
            return ra == rb ? a.offset < b.offset : ra < rb
        }.map(\.element)
        return (sorted, ignored)
    }
}
