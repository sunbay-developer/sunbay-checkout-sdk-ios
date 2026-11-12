import Foundation

/// A default input-length cap for the postal code field (Foundation-only, UI-agnostic).
///
/// The longest real-world postal codes are about 10 characters (for example Iran, 10 digits; Brazil,
/// 9 with the hyphen), so 12 leaves room for separators and spaces while still rejecting pasted junk.
/// It limits typing only; whether a value is acceptable stays with `PostalCodeValidator`.
enum PostalCodeInputLimit {
    /// The maximum number of characters accepted in the postal code field.
    static let maxLength = 12

    /// Whether an edit may be applied to the field.
    ///
    /// - Parameters:
    ///   - current: The field text before the edit.
    ///   - range: The replaced range, as reported by `shouldChangeCharactersIn`.
    ///   - replacement: The replacement string (empty for a delete).
    /// - Returns: `true` when the edit is a deletion or the result stays within `maxLength`.
    static func allows(current: String, range: NSRange, replacement: String) -> Bool {
        let ns = current as NSString
        guard range.location != NSNotFound, range.location + range.length <= ns.length else { return false }
        let result = ns.replacingCharacters(in: range, with: replacement)
        return replacement.isEmpty || result.count <= maxLength
    }
}
