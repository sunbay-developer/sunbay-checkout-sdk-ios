import Foundation

/// Read-only display information for a saved card (COF).
///
/// Contains only non-sensitive information used for list display (brand and
/// last four digits); it does not include the full card number or CVV.
public struct SavedCard: Sendable, Equatable {
    /// Identifier of the saved payment method.
    public let id: String
    /// Card brand (such as `"visa"`).
    public let brand: String
    /// Last four digits of the card number.
    public let last4: String
    /// Expiry month.
    public let expMonth: Int
    /// Expiry year.
    public let expYear: Int

    /// Creates saved card display information.
    ///
    /// - Parameters:
    ///   - id: Identifier of the saved payment method.
    ///   - brand: Card brand.
    ///   - last4: Last four digits of the card number.
    ///   - expMonth: Expiry month.
    ///   - expYear: Expiry year.
    public init(id: String, brand: String, last4: String, expMonth: Int, expYear: Int) {
        self.id = id
        self.brand = brand
        self.last4 = last4
        self.expMonth = expMonth
        self.expYear = expYear
    }
}
