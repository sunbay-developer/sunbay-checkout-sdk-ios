import Foundation

/// A catalog item. Prices are USD minor units (cents).
struct Product: Identifiable, Equatable {
    let id: String
    /// Localization key resolved through `Strings`.
    let nameKey: String
    let priceMinor: Int64
    /// SF Symbol name.
    let symbol: String
}

enum Catalog {
    static let products: [Product] = [
        Product(id: "headphones", nameKey: "product.headphones", priceMinor: 14_900, symbol: "headphones"),
        Product(id: "watch", nameKey: "product.watch", priceMinor: 12_900, symbol: "applewatch"),
        Product(id: "backpack", nameKey: "product.backpack", priceMinor: 6_900, symbol: "bag"),
        Product(id: "bottle", nameKey: "product.bottle", priceMinor: 2_400, symbol: "cup.and.saucer"),
        Product(id: "notebook", nameKey: "product.notebook", priceMinor: 1_200, symbol: "book.closed"),
    ]
}
