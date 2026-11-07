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
        // Coffee-shop menu. SF Symbols are all available on iOS 15.
        Product(id: "latte", nameKey: "product.latte", priceMinor: 550, symbol: "cup.and.saucer"),
        Product(id: "americano", nameKey: "product.americano", priceMinor: 400, symbol: "mug"),
        Product(id: "coldbrew", nameKey: "product.coldbrew", priceMinor: 475, symbol: "takeoutbag.and.cup.and.straw"),
        Product(id: "croissant", nameKey: "product.croissant", priceMinor: 350, symbol: "fork.knife"),
        Product(id: "beans", nameKey: "product.beans", priceMinor: 1_600, symbol: "bag"),
    ]
}
