import Foundation

/// Pure formatting / validation rules for the card expiry field (`MM/YY`).
///
/// UI-agnostic (no UIKit) so the rules are testable on the host. Mirrors the web checkout's behavior:
/// smart zero-padding of the month, month range enforcement, a Backspace that also removes the
/// auto-inserted `/`, and an expiry check that rejects past dates.
enum ExpiryFormatter {
    /// The outcome of applying one edit to the expiry text.
    struct Edit: Equatable {
        /// The new field text (`MM`, `MM/`, `MM/Y`, `MM/YY`, …).
        let text: String
        /// Caret position in `text`, as a UTF-16 offset.
        let caret: Int
        /// Whether the text now holds a full `MM/YY` value (the UI may advance focus).
        let isComplete: Bool
    }

    /// Applies a keystroke / paste / delete to the current text.
    ///
    /// - Parameters:
    ///   - current: The field text before the edit.
    ///   - range: The replaced range, as reported by `shouldChangeCharactersIn`.
    ///   - replacement: The replacement string (empty for a delete).
    /// - Returns: The formatted result, or `nil` when the edit must be rejected (invalid month).
    static func apply(current: String, range: NSRange, replacement: String) -> Edit? {
        let ns = current as NSString
        guard range.location != NSNotFound, range.location + range.length <= ns.length else { return nil }
        let updated = ns.replacingCharacters(in: range, with: replacement)
        let deleting = replacement.isEmpty
        let currentDigits = current.filter(\.isASCIIDigit)
        var digits = updated.filter(\.isASCIIDigit)
        var jumpToEnd = false

        // Pasted `MMYYYY` / `MM/YYYY` (month, then a 20xx year): keep MM and the last two year digits.
        if digits.count == 6, digits.dropFirst(2).hasPrefix("20") {
            digits = String(digits.prefix(2)) + String(digits.suffix(2))
            jumpToEnd = true
        } else if digits.count > 4 {
            digits = String(digits.prefix(4))
            jumpToEnd = true
        }

        // Backspace that only removed the auto-inserted `/` would be re-added by formatting and look
        // stuck: treat it as deleting the digit before it.
        if deleting, !digits.isEmpty, digits == currentDigits {
            digits.removeLast()
            jumpToEnd = true
        }

        // A first digit of 2–9 cannot start a month: pad to `0X` (4 -> 04).
        if !deleting, digits.count == 1, let first = digits.first, first > "1" {
            digits = "0" + digits
            jumpToEnd = true
        }

        // Month must be 01–12 as soon as it is typed.
        if digits.count >= 1, let first = digits.first, first > "1" { return nil }
        if digits.count >= 2 {
            guard let month = Int(digits.prefix(2)), (1...12).contains(month) else { return nil }
        }

        let text = display(digits: digits, deleting: deleting)
        let caretInUpdated = range.location + (replacement as NSString).length
        let atEnd = caretInUpdated >= (updated as NSString).length
        let caret: Int
        if jumpToEnd || atEnd {
            caret = (text as NSString).length
        } else {
            let before = (updated as NSString).substring(to: min(caretInUpdated, (updated as NSString).length))
            caret = offset(afterDigits: before.filter(\.isASCIIDigit).count, in: text, deleting: deleting)
        }
        return Edit(text: text, caret: caret, isComplete: digits.count == 4)
    }

    /// Formats a digit string for display: `MM` stays bare while deleting, and becomes `MM/` when typing.
    private static func display(digits: String, deleting: Bool) -> String {
        switch digits.count {
        case 0, 1: return digits
        case 2: return deleting ? digits : digits + "/"
        default: return String(digits.prefix(2)) + "/" + String(digits.dropFirst(2))
        }
    }

    /// UTF-16 offset in `text` just after its `count`-th digit (past a following `/` while typing).
    private static func offset(afterDigits count: Int, in text: String, deleting: Bool) -> Int {
        if count <= 0 { return 0 }
        var seen = 0
        var index = 0
        for character in text {
            index += character.utf16.count
            if character.isASCIIDigit { seen += 1 }
            if seen == count { break }
        }
        if !deleting, count == 2, text.count > 2 { index += 1 }
        return min(index, (text as NSString).length)
    }

    // MARK: - Validation / contract

    /// Splits `MM/YY` into the backend contract: a 2-digit month and a **4-digit** year (`"20" + YY`).
    /// Returns `nil` unless both parts are well formed.
    static func components(from text: String) -> (month: String, year: String)? {
        let parts = text.split(separator: "/", maxSplits: 1, omittingEmptySubsequences: false)
        guard parts.count == 2 else { return nil }
        let month = parts[0].trimmingCharacters(in: .whitespaces)
        let year = parts[1].trimmingCharacters(in: .whitespaces)
        guard month.count == 2, year.count == 2, month.allSatisfy(\.isASCIIDigit), year.allSatisfy(\.isASCIIDigit)
        else { return nil }
        return (month, "20" + year)
    }

    /// Whether the month is 01–12 and the month is not before `now`'s month (expiry is inclusive of
    /// the card's last valid month).
    static func isValid(month: String, year: String, now: Date = Date()) -> Bool {
        guard let m = Int(month), let y = Int(year), (1...12).contains(m) else { return false }
        let calendar = Calendar(identifier: .gregorian)
        let nowYear = calendar.component(.year, from: now)
        let nowMonth = calendar.component(.month, from: now)
        return y > nowYear || (y == nowYear && m >= nowMonth)
    }
}

extension Character {
    /// `0`–`9` only (not other scripts' digits).
    fileprivate var isASCIIDigit: Bool { ("0"..."9").contains(self) }
}
