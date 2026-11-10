import Foundation

/// The two address kinds a session can ask for.
enum AddressKind: String, Sendable {
    case billing
    case shipping

    /// The host-facing option name used in warnings (`ignored`), never a value.
    var identifier: String { "\(rawValue)Address" }
}

/// Which Apple Pay contacts the wallet sheet must request.
struct WalletContactRequest: Equatable, Sendable {
    var billing: Bool
    var shipping: Bool
}

/// The result of a wallet authorization: the payment token and the contacts the sheet returned.
///
/// Holds PII and the wallet token: never printed, logged or returned to the host.
struct WalletAuthorization: Sendable {
    let token: Data
    let billing: AddressInput?
    let shipping: AddressInput?
    let email: String?
}

/// Pure address rules shared by every payment path (mirrors the JS `hostAddress` rules).
enum AddressRules {
    /// Trims every field; blank fields become nil. Returns nil for nil input or when nothing non-blank remains.
    static func sanitize(_ a: AddressInput?) -> AddressInput? {
        guard let a else { return nil }
        let out = AddressInput(
            country: clean(a.country), line1: clean(a.line1), line2: clean(a.line2),
            city: clean(a.city), state: clean(a.state), postalCode: clean(a.postalCode),
            district: clean(a.district), firstName: clean(a.firstName), lastName: clean(a.lastName),
            phone: clean(a.phone), email: clean(a.email))
        return out == AddressInput() ? nil : out
    }

    /// Whether the address has every field the kind requires (billing: country, city, line1, postal code;
    /// shipping: those plus first name, last name and phone).
    static func isComplete(_ kind: AddressKind, _ a: AddressInput?) -> Bool {
        guard let a else { return false }
        var required = [a.country, a.city, a.line1, a.postalCode]
        if kind == .shipping { required += [a.firstName, a.lastName, a.phone] }
        return required.allSatisfy { clean($0) != nil }
    }

    /// Whether any non-blank field other than `country` is present (the country alone is a default, not a draft).
    static func hasDraftContent(_ a: AddressInput?) -> Bool {
        guard var s = sanitize(a) else { return false }
        s.country = nil
        return s != AddressInput()
    }

    /// `"first last"` of the shipping address when both names are present, else of billing, else nil.
    static func customerName(billing: AddressInput?, shipping: AddressInput?) -> String? {
        fullName(shipping) ?? fullName(billing)
    }

    private static func fullName(_ a: AddressInput?) -> String? {
        guard let first = clean(a?.firstName), let last = clean(a?.lastName) else { return nil }
        return "\(first) \(last)"
    }

    private static func clean(_ s: String?) -> String? {
        guard let t = s?.trimmingCharacters(in: .whitespacesAndNewlines), !t.isEmpty else { return nil }
        return t
    }
}
