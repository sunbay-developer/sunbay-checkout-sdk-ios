import Foundation

/// The saved-card (COF) list state shared by the UI shells: card order, the selected card, the default
/// card, expiry, and which cards have a delete in flight.
///
/// Pure logic (no UIKit): the content view controller renders it, and an embedded rows view can reuse it.
/// Behavior mirrors what the content VC did inline:
/// - usable cards come first, expired ones stay (dimmed, never selectable) at the end;
/// - `selectedId` starts `nil`; the shell calls `selectDefault()` where it wants the first usable card
///   pre-selected;
/// - removing the selected card clears the selection and never auto-reselects.
struct SavedCardSelection {
    private let clock: @Sendable () -> Date

    /// The cards, usable first (original order kept within each group).
    private(set) var cards: [SavedCard]
    /// The selected card id, or nil when nothing is selected.
    private(set) var selectedId: String?
    /// Ids with a delete request in flight.
    private(set) var deletingIds: Set<String> = []

    /// - Parameters:
    ///   - cards: The saved cards as returned by the backend.
    ///   - clock: The reference date for expiry (injectable for tests).
    init(cards: [SavedCard], clock: @escaping @Sendable () -> Date = { Date() }) {
        self.clock = clock
        self.cards = SavedCardExpiry.usableFirst(cards, at: clock())
    }

    var isEmpty: Bool { cards.isEmpty }

    /// The first usable (non-expired) card, or nil when every card is expired.
    var defaultId: String? {
        cards.first { !isExpired($0) }?.id
    }

    func isExpired(_ card: SavedCard) -> Bool {
        SavedCardExpiry.isExpired(card, at: clock())
    }

    /// Sets the selection without any check (what the content VC did by assigning directly).
    mutating func setSelectedId(_ id: String?) {
        selectedId = id
    }

    /// Selects the default (first usable) card; leaves the selection `nil` when every card is expired.
    mutating func selectDefault() {
        selectedId = defaultId
    }

    /// Selects a card the user may pay with.
    ///
    /// - Returns: `false` (and changes nothing) when the card is unknown, expired, or being deleted.
    @discardableResult
    mutating func select(_ id: String) -> Bool {
        guard let card = cards.first(where: { $0.id == id }), !isExpired(card), !deletingIds.contains(id) else {
            return false
        }
        selectedId = id
        return true
    }

    mutating func clearSelection() {
        selectedId = nil
    }

    /// Removes a card (after a successful delete). Clears the selection when it was the selected one and
    /// never reselects another card.
    mutating func remove(_ id: String) {
        cards.removeAll { $0.id == id }
        deletingIds.remove(id)
        if selectedId == id { selectedId = nil }
    }

    /// Marks a delete as in flight.
    ///
    /// - Returns: `false` when the card is unknown or already being deleted.
    @discardableResult
    mutating func beginDelete(_ id: String) -> Bool {
        guard cards.contains(where: { $0.id == id }), !deletingIds.contains(id) else { return false }
        deletingIds.insert(id)
        return true
    }

    /// Clears a delete's in-flight mark (after a failure).
    mutating func endDelete(_ id: String) {
        deletingIds.remove(id)
    }
}
