import Foundation

extension CheckoutError {
    /// Returns a user-facing, localized message for this error.
    ///
    /// The stable `code` is mapped to the key `sunbay.error.<lowercasedCode>`
    /// and resolved through `resolver`. When no entry exists for the key, the
    /// resolver returns the key unchanged; in that case this falls back to the
    /// developer-facing `message` so the result is never empty (an unmapped or
    /// future code still yields something meaningful).
    ///
    /// - Parameter resolver: The resolver bound to the chosen locale.
    /// - Returns: The localized display message, or `message` when unmapped.
    func localizedDisplayMessage(using resolver: LocalizationResolver) -> String {
        let key = "sunbay.error." + code.lowercased()
        let resolved = resolver.localized(key, "")
        if resolved == key {
            return message
        }
        return resolved
    }
}
