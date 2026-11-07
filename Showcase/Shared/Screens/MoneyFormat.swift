import Foundation

/// Formats USD minor units (cents) as a localized currency string, e.g. 14900 -> "$149.00".
func formatUSD(minor: Int64) -> String {
    let formatter = NumberFormatter()
    formatter.numberStyle = .currency
    formatter.currencyCode = "USD"
    formatter.locale = Locale(identifier: "en_US")
    return formatter.string(from: NSDecimalNumber(value: minor).multiplying(byPowerOf10: -2)) ?? "$\(minor)"
}
