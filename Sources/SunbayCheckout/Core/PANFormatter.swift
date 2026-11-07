import Foundation

/// Pure, UI-agnostic editing rules for the card-number field.
///
/// Handles the local interaction details of a grouped input: Backspace over a group separator,
/// caret preservation for edits in the middle of the number, and pasted values. The grouping itself
/// lives in `format(_:)` — a single place to swap for brand-specific grouping later.
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

    /// Groups digits into blocks of four separated by a single space (display only), capped at
    /// `maxDigits`. Non-digit characters are dropped.
    static func format(_ raw: String) -> String {
        let digits = String(raw.filter(\.isASCIIDigit).prefix(maxDigits))
        var grouped = ""
        for (index, character) in digits.enumerated() {
            if index != 0, index % 4 == 0 { grouped.append(" ") }
            grouped.append(character)
        }
        return grouped
    }

    /// Applies a keystroke / paste / delete to the current text.
    ///
    /// - Parameters:
    ///   - current: The field text before the edit.
    ///   - range: The replaced range, as reported by `shouldChangeCharactersIn`.
    ///   - replacement: The replacement string (empty for a delete).
    /// - Returns: The formatted text and caret, or `nil` if `range` is out of bounds.
    static func apply(current: String, range: NSRange, replacement: String) -> Edit? {
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

        let text = format(digits)
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
