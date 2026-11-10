import Foundation

/// The outcome of validating a postal code against a country's field config.
enum PostalCodeValidationResult: Equatable {
    /// The value is acceptable (or there is nothing to validate).
    case valid
    /// The field is required but empty.
    case required
    /// The value is non-empty but does not match the country's pattern.
    case invalidFormat
}

/// Validates a postal code against an `AddressFieldConfig` (Foundation-only, UI-agnostic).
enum PostalCodeValidator {
    /// Validates a postal code.
    ///
    /// Whitespace is trimmed first. An empty value is `.required` only when the config marks the field
    /// required. A non-empty value is checked against the config pattern, and the whole trimmed value must
    /// match. A missing config, missing pattern or a pattern that fails to compile is treated as valid.
    ///
    /// - Parameters:
    ///   - value: The user-entered postal code.
    ///   - config: The postal-code field config for the selected country; nil when unknown.
    /// - Returns: The validation result.
    static func validate(_ value: String?, config: AddressFieldConfig?) -> PostalCodeValidationResult {
        guard let config = config else { return .valid }
        let trimmed = (value ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            return config.required ? .required : .valid
        }
        guard let pattern = config.pattern, !pattern.isEmpty,
              // Wrap in a non-capturing group with absolute anchors so alternation (e.g. ZIP vs ZIP+4)
              // must match the whole value rather than the first alternative that succeeds.
              let regex = try? NSRegularExpression(pattern: "\\A(?:\(pattern))\\z") else {
            return .valid
        }
        let full = NSRange(trimmed.startIndex..<trimmed.endIndex, in: trimmed)
        return regex.firstMatch(in: trimmed, options: [], range: full) == nil ? .invalidFormat : .valid
    }
}
