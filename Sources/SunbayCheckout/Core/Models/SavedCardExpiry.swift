import Foundation

/// Local expiry rules for saved cards (COF).
///
/// The backend does not mark expired cards yet, so the SDK decides from `expMonth` / `expYear`. A
/// card stays valid through the last day of its expiry month, so it counts as expired only once the
/// current month is past the expiry month. Pure logic (no UIKit); swap for a backend status field
/// once one exists.
enum SavedCardExpiry {
    /// Whether `card` is expired at `date`.
    ///
    /// - Parameters:
    ///   - card: The saved card.
    ///   - date: The reference date (normally now).
    ///   - calendar: The calendar used to read the current year and month.
    /// - Returns: `true` when the current year/month is after the card's expiry year/month.
    static func isExpired(_ card: SavedCard, at date: Date, calendar: Calendar = .current) -> Bool {
        let now = calendar.dateComponents([.year, .month], from: date)
        guard let year = now.year, let month = now.month else { return false }
        if card.expYear != year { return card.expYear < year }
        return card.expMonth < month
    }

    /// Orders cards so usable ones come first; the original order is kept within each group.
    ///
    /// - Parameters:
    ///   - cards: The saved cards as returned by the backend.
    ///   - date: The reference date (normally now).
    ///   - calendar: The calendar used to read the current year and month.
    /// - Returns: The usable cards followed by the expired ones.
    static func usableFirst(_ cards: [SavedCard], at date: Date, calendar: Calendar = .current) -> [SavedCard] {
        let usable = cards.filter { !isExpired($0, at: date, calendar: calendar) }
        let expired = cards.filter { isExpired($0, at: date, calendar: calendar) }
        return usable + expired
    }
}
