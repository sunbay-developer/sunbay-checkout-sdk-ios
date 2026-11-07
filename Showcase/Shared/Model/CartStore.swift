import Foundation

/// In-memory shopping cart keyed by `Product.id`.
final class CartStore: ObservableObject {
    @Published private(set) var quantities: [String: Int] = [:]

    func add(_ p: Product) {
        quantities[p.id, default: 0] += 1
    }

    /// Sets the quantity for a product; a value of 0 or less removes the line.
    func setQuantity(_ p: Product, _ q: Int) {
        if q <= 0 {
            quantities.removeValue(forKey: p.id)
        } else {
            quantities[p.id] = q
        }
    }

    /// Cart lines in catalog order.
    var lines: [(Product, Int)] {
        Catalog.products.compactMap { p in
            quantities[p.id].map { (p, $0) }
        }
    }

    var totalMinor: Int64 {
        lines.reduce(0) { $0 + $1.0.priceMinor * Int64($1.1) }
    }

    var itemCount: Int { quantities.values.reduce(0, +) }

    var isEmpty: Bool { quantities.isEmpty }

    func clear() {
        quantities = [:]
    }

    /// "SB-" followed by exactly six digits.
    static func makeOrderNumber() -> String {
        "SB-" + String(format: "%06d", Int.random(in: 0...999_999))
    }
}
