import Foundation

/// A payment method the SDK can render, keyed by logical key.
struct PaymentProvider: Equatable {
    enum Kind { case express, normal }
    let key: String
    let kind: Kind
}

/// The providers the SDK knows about and the rule that decides which are offered.
enum PaymentProviderRegistry {
    static let all: [PaymentProvider] = [
        PaymentProvider(key: "APPLE_PAY", kind: .express),
        PaymentProvider(key: "CARD", kind: .normal),
    ]

    /// Providers with a matching entry whose static check passes: the express group first, then the normal
    /// group; inside a group, in the order of their first matching entry.
    static func available(
        entries: [MethodEntry], isStaticallyAvailable: (PaymentProvider) -> Bool
    ) -> [PaymentProvider] {
        func firstIndex(_ p: PaymentProvider) -> Int? {
            entries.firstIndex { PaymentMethodModel.logicalKey($0) == p.key }
        }
        let offered = all.compactMap { p -> (PaymentProvider, Int)? in
            guard let index = firstIndex(p), isStaticallyAvailable(p) else { return nil }
            return (p, index)
        }
        return [PaymentProvider.Kind.express, .normal].flatMap { kind in
            offered.filter { $0.0.kind == kind }.sorted { $0.1 < $1.1 }.map(\.0)
        }
    }
}
