import Foundation

/// Why a card entry cannot be submitted yet (UI-agnostic, no card data retained).
///
/// Used by the card form to show a specific message instead of a generic one. The checks stay lenient
/// (contract principle 3): only the impossible is rejected, everything else is left to the backend.
enum CardValidationIssue: Equatable {
    case numberEmpty
    case numberIncomplete
    case numberInvalid
    case expiryEmpty
    case expiryIncomplete
    case expiryMonthInvalid
    case expiryPast
    case cvcEmpty
    case cvcIncomplete

    /// The localization key of the user-facing message for this issue.
    var messageKey: String {
        switch self {
        case .numberEmpty: return "sunbay.card.error.numberEmpty"
        case .numberIncomplete: return "sunbay.card.error.numberIncomplete"
        case .numberInvalid: return "sunbay.card.error.numberInvalid"
        case .expiryEmpty: return "sunbay.card.error.expiryEmpty"
        case .expiryIncomplete: return "sunbay.card.error.expiryIncomplete"
        case .expiryMonthInvalid: return "sunbay.card.error.expiryMonthInvalid"
        case .expiryPast: return "sunbay.card.error.expiryPast"
        case .cvcEmpty: return "sunbay.card.error.cvcEmpty"
        case .cvcIncomplete: return "sunbay.card.error.cvcIncomplete"
        }
    }
}

/// Pure card-entry validation shared by `cardInput` assembly and the error message.
enum CardValidation {
    /// The first problem in the entry, checked in field order (number, expiry, security code), or `nil`
    /// when the entry can be submitted.
    ///
    /// - Parameters:
    ///   - pan: The number as displayed (grouping spaces allowed).
    ///   - expiry: The expiry as displayed (`MM/YY`).
    ///   - cvv: The security code.
    ///   - rules: The effective brand rules (UnionPay skips the Luhn check; security-code length).
    ///   - now: The reference date for the expiry check.
    static func firstIssue(
        pan: String, expiry: String, cvv: String, rules: CardRules, now: Date = Date()
    ) -> CardValidationIssue? {
        let digits = pan.filter { !$0.isWhitespace }
        if digits.isEmpty { return .numberEmpty }
        guard digits.allSatisfy(\.isASCIIDigit), (12...19).contains(digits.count) else {
            return .numberIncomplete
        }
        if rules.scheme != "unionpay", !CardScanParser.luhnValid(digits) { return .numberInvalid }

        let trimmedExpiry = expiry.trimmingCharacters(in: .whitespaces)
        if trimmedExpiry.isEmpty { return .expiryEmpty }
        guard let (month, year) = ExpiryFormatter.components(from: trimmedExpiry) else {
            return .expiryIncomplete
        }
        guard let m = Int(month), (1...12).contains(m) else { return .expiryMonthInvalid }
        if !ExpiryFormatter.isValid(month: month, year: year, now: now) { return .expiryPast }

        let code = cvv.trimmingCharacters(in: .whitespaces)
        if code.isEmpty { return .cvcEmpty }
        let minimum = max(3, rules.cvvSizes.min() ?? 3)
        guard code.allSatisfy(\.isASCIIDigit), (minimum...4).contains(code.count) else {
            return .cvcIncomplete
        }
        return nil
    }
}
