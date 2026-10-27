import Foundation

/// Payment amount.
///
/// The amount is expressed in integer minor units to avoid floating-point
/// errors; for example, 9.99 USD is recorded as `minorUnits = 999` and
/// `currencyCode = "USD"`.
public struct Amount: Sendable, Equatable {
    /// The number of minor currency units (such as "cents").
    public let minorUnits: Int64
    /// ISO 4217 currency code (such as `"USD"`).
    public let currencyCode: String

    /// Creates an amount.
    ///
    /// - Parameters:
    ///   - minorUnits: The number of minor currency units.
    ///   - currencyCode: ISO 4217 currency code.
    public init(minorUnits: Int64, currencyCode: String) {
        self.minorUnits = minorUnits
        self.currencyCode = currencyCode
    }
}
