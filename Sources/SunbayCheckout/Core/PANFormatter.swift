import Foundation

/// Pure, UI-agnostic editing rules for the card-number field.
///
/// Handles the local interaction details of a grouped input: Backspace over a group separator,
/// caret preservation for edits in the middle of the number, and pasted values. The grouping itself
/// comes from the effective `CardRules` (brand-specific when a scheme is known).
enum PANFormatter {
    /// The longest supported PAN.
    static let maxDigits = 19

    /// The outcome of applying one edit to the number text.
    struct Edit: Equatable {
        /// The new field text (digits grouped by `format(_:)`).
        let text: String
        /// Caret position in `text`, as a UTF-16 offset.
        let caret: Int
        /// Whether the caret ended up at the end of the text.
        let caretAtEnd: Bool
    }

    /// Groups digits for display using the rules' group sizes (digits beyond the sum are grouped by
    /// four), separated by a single space. Capped at `maxDigits`; non-digit characters are dropped.
    static func format(_ raw: String, rules: CardRules = .generic) -> String {
        let digits = Array(raw.filter(\.isASCIIDigit).prefix(maxDigits))
        let sizes = rules.groupSizes(forDigitCount: digits.count)
        var grouped = ""
        var index = 0
        var sizeIndex = 0
        while index < digits.count {
            let size = sizeIndex < sizes.count ? sizes[sizeIndex] : 4
            if index != 0 { grouped.append(" ") }
            grouped.append(contentsOf: digits[index..<min(index + size, digits.count)])
            index += size
            sizeIndex += 1
        }
        return grouped
    }

    /// Re-groups an existing text after the rules changed (for example a scheme arrived), keeping the
    /// caret next to the same digit. Never adds or removes digits.
    ///
    /// - Parameters:
    ///   - text: The current field text.
    ///   - caret: The caret position (UTF-16 offset) in `text`.
    static func reformat(_ text: String, caret: Int, rules: CardRules) -> Edit {
        let ns = text as NSString
        let digitsBeforeCaret = ns.substring(to: max(0, min(caret, ns.length))).filter(\.isASCIIDigit).count
        let digits = text.filter(\.isASCIIDigit)
        let formatted = format(digits, rules: rules)
        let length = (formatted as NSString).length
        let atEnd = digitsBeforeCaret >= digits.count
        return Edit(
            text: formatted, caret: atEnd ? length : min(offset(afterDigits: digitsBeforeCaret, in: formatted), length),
            caretAtEnd: atEnd)
    }

    /// Applies a keystroke / paste / delete to the current text.
    ///
    /// - Parameters:
    ///   - current: The field text before the edit.
    ///   - range: The replaced range, as reported by `shouldChangeCharactersIn`.
    ///   - replacement: The replacement string (empty for a delete).
    ///   - rules: The rules in effect (grouping).
    /// - Returns: The formatted text and caret, or `nil` if `range` is out of bounds.
    static func apply(
        current: String, range: NSRange, replacement: String, rules: CardRules = .generic
    ) -> Edit? {
        let ns = current as NSString
        guard range.location != NSNotFound, range.location + range.length <= ns.length else { return nil }
        let updated = ns.replacingCharacters(in: range, with: replacement)
        let deleting = replacement.isEmpty
        let currentDigits = current.filter(\.isASCIIDigit)
        var digits = updated.filter(\.isASCIIDigit)

        // Digits that precede the caret after the edit.
        let caretInUpdated = range.location + (replacement as NSString).length
        var digitsBeforeCaret = (updated as NSString).substring(to: min(caretInUpdated, (updated as NSString).length))
            .filter(\.isASCIIDigit).count
        var forceEnd = false

        // Backspace that removed only a group separator (digits unchanged) would be re-added by
        // formatting and look stuck: delete the digit in front of the separator instead.
        if deleting, !digits.isEmpty, digits == currentDigits, digitsBeforeCaret > 0 {
            digits.remove(at: digits.index(digits.startIndex, offsetBy: digitsBeforeCaret - 1))
            digitsBeforeCaret -= 1
        }

        if digits.count > maxDigits {
            digits = String(digits.prefix(maxDigits))
            forceEnd = true  // an over-long paste: land at the end
        }

        let text = format(digits, rules: rules)
        let length = (text as NSString).length
        let caretAtEnd = forceEnd || digitsBeforeCaret >= digits.count
        let caret = caretAtEnd ? length : offset(afterDigits: digitsBeforeCaret, in: text)
        return Edit(text: text, caret: min(caret, length), caretAtEnd: caretAtEnd)
    }

    /// UTF-16 offset in `text` immediately after its `count`-th digit (0 for none).
    private static func offset(afterDigits count: Int, in text: String) -> Int {
        guard count > 0 else { return 0 }
        var seen = 0
        var index = 0
        for character in text {
            index += character.utf16.count
            if character.isASCIIDigit { seen += 1 }
            if seen == count { break }
        }
        return index
    }
}
