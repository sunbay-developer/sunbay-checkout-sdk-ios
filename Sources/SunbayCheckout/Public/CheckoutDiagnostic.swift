import Foundation

/// A non-fatal advisory: the SDK ignored or adjusted some host input and carried on.
///
/// Warnings never contain card values, wallet tokens, secrets or address contents; `ignored` lists
/// only field / option names (for example `"billingAddress"`).
public struct CheckoutWarning: Sendable, Equatable {
    /// A stable, string-backed warning code.
    public struct Code: RawRepresentable, Hashable, Sendable, ExpressibleByStringLiteral {
        public let rawValue: String

        public init(rawValue: String) {
            self.rawValue = rawValue
        }

        public init(stringLiteral value: String) {
            self.rawValue = value
        }

        /// The host's payment-method filter matched nothing usable and was ignored.
        public static let paymentMethodFilterIgnored: Code = "PAYMENT_METHOD_FILTER_IGNORED"
        /// A host-supplied address was missing required parts and was not used.
        public static let addressIncomplete: Code = "ADDRESS_INCOMPLETE"
        /// A host-supplied address entry was ignored.
        public static let addressEntryIgnored: Code = "ADDRESS_ENTRY_IGNORED"
        /// Wallet parameters were invalid and were ignored.
        public static let walletParamsInvalid: Code = "WALLET_PARAMS_INVALID"
    }

    /// The warning code.
    public let code: Code
    /// Names of the ignored inputs (never values).
    public let ignored: [String]
    /// A developer-facing explanation.
    public let reason: String
    /// The checkout session the warning relates to, when known.
    public let sessionId: String?

    public init(code: Code, ignored: [String], reason: String, sessionId: String?) {
        self.code = code
        self.ignored = ignored
        self.reason = reason
        self.sessionId = sessionId
    }
}

/// A diagnostic event delivered through `SunbayCheckout.onDiagnostic`.
public enum CheckoutDiagnostic: Sendable, Equatable {
    /// A non-fatal advisory about host input.
    case warning(CheckoutWarning)
    /// A non-terminal error the SDK recovered from (it does not end the checkout).
    case error(CheckoutError, sessionId: String?)
}
