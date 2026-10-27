import Foundation

/// Formats an ``Amount`` as a locale-aware currency string.
///
/// The SDK stores amounts in integer minor units (see ``Amount``). The number
/// of minor units per major unit depends on the currency: most currencies use
/// two fraction digits (USD cents), while others use zero (JPY) or three. This
/// formatter derives the correct scale from the currency itself rather than
/// assuming a fixed divisor such as `/100`.
///
/// Conversion from minor to major units uses `Decimal` arithmetic so that the
/// value is exact; `Double` is avoided to prevent floating-point rounding
/// error (for example, representing cents).
///
/// This type imports `Foundation` only and holds no UI dependency, keeping the
/// Core layer UI-agnostic.
struct AmountFormatter {
    /// Formats `amount` for display in `locale`.
    ///
    /// The fraction-digit count (and therefore the minor-to-major divisor) is
    /// taken from a `NumberFormatter` configured for `amount.currencyCode`, so
    /// JPY (0 digits), USD (2 digits), and any other currency all scale
    /// correctly.
    ///
    /// - Parameters:
    ///   - amount: The amount to format, in integer minor units.
    ///   - locale: The locale that determines symbol placement, grouping, and
    ///     decimal separators.
    /// - Returns: The localized currency string. When the underlying formatter
    ///   cannot produce a string, the raw minor-unit value is returned as a
    ///   plain decimal fallback.
    func string(from amount: Amount, locale: Locale) -> String {
        let formatter = NumberFormatter()
        formatter.numberStyle = .currency
        formatter.locale = locale
        formatter.currencyCode = amount.currencyCode

        // Setting a currency code also configures the formatter's fraction
        // digits to that currency's convention (2 for USD, 0 for JPY, ...).
        let fractionDigits = formatter.maximumFractionDigits

        // Divisor is 10^fractionDigits: 100 for USD, 1 for JPY (no scaling).
        var divisor = Decimal(1)
        for _ in 0..<fractionDigits {
            divisor *= 10
        }

        // Exact minor-to-major conversion via Decimal, never Double.
        let minorUnits = Decimal(amount.minorUnits)
        let majorUnits = minorUnits / divisor

        let number = NSDecimalNumber(decimal: majorUnits)
        if let formatted = formatter.string(from: number) {
            return formatted
        }

        // Fallback that never exposes anything sensitive; amounts are not
        // sensitive data, so returning the plain value here is safe.
        return majorUnits.description
    }
}
