import Foundation

/// Identifies a payment method in a `PaymentMethodFilter`.
///
/// Identifiers are case-sensitive. A logical key (`CARD`, `APPLE_PAY`) is matched first (`CARD` covers every
/// card entry of the session); otherwise the identifier is matched against the raw backend method (for example `AMEX`).
public struct PaymentMethodID: RawRepresentable, Hashable, Sendable, ExpressibleByStringLiteral {
    /// The identifier text.
    public let rawValue: String

    /// Creates an identifier from its text.
    public init(rawValue: String) {
        self.rawValue = rawValue
    }

    /// Creates an identifier from a string literal.
    public init(stringLiteral value: String) {
        self.rawValue = value
    }

    /// Every card entry (new card and saved cards).
    public static let card: PaymentMethodID = "CARD"
    /// Apple Pay.
    public static let applePay: PaymentMethodID = "APPLE_PAY"
}

/// Lets the host hide payment methods and reorder the rest.
///
/// `hide` wins over `order`. `order` is stable: unlisted items keep their relative order after the listed ones,
/// and it never moves a group (the express group position comes from the appearance). An identifier that matches
/// nothing is ignored and reported as a `PAYMENT_METHOD_FILTER_IGNORED` diagnostic; the filter never fails a payment.
public struct PaymentMethodFilter: Sendable, Equatable {
    /// Methods to hide.
    public var hide: [PaymentMethodID]
    /// Preferred order of the remaining methods.
    public var order: [PaymentMethodID]

    /// Creates a filter.
    public init(hide: [PaymentMethodID] = [], order: [PaymentMethodID] = []) {
        self.hide = hide
        self.order = order
    }
}
