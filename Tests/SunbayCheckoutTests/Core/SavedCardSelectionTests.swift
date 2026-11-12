import XCTest

@testable import SunbayCheckout

/// The saved-card list state shared by the UI shells: ordering, the default card, selection rules and
/// delete bookkeeping. Pure logic; the clock is fixed to 2026-11-12.
final class SavedCardSelectionTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_794_000_000)  // 2026-11-12 (UTC)

    private func card(_ id: String, month: Int = 12, year: Int = 2099) -> SavedCard {
        SavedCard(id: id, brand: "visa", last4: "4242", expMonth: month, expYear: year)
    }

    private func expired(_ id: String) -> SavedCard { card(id, month: 1, year: 2020) }

    private func make(_ cards: [SavedCard]) -> SavedCardSelection {
        SavedCardSelection(cards: cards, clock: { [now] in now })
    }

    func test_init_ordersUsableBeforeExpired_keepingOrderWithinGroups() {
        let selection = make([expired("e1"), card("a"), expired("e2"), card("b")])
        XCTAssertEqual(selection.cards.map(\.id), ["a", "b", "e1", "e2"])
    }

    func test_defaultId_isFirstUsable_andNilWhenAllExpired() {
        XCTAssertEqual(make([expired("e1"), card("a")]).defaultId, "a")
        XCTAssertNil(make([expired("e1"), expired("e2")]).defaultId)
        XCTAssertNil(make([]).defaultId)
    }

    func test_selectedId_startsNil() {
        XCTAssertNil(make([card("a")]).selectedId)
    }

    func test_selectDefault_selectsFirstUsable() {
        var selection = make([expired("e1"), card("a"), card("b")])
        selection.selectDefault()
        XCTAssertEqual(selection.selectedId, "a")
    }

    func test_selectDefault_whenAllExpired_leavesSelectionNil() {
        var selection = make([expired("e1")])
        selection.selectDefault()
        XCTAssertNil(selection.selectedId)
    }

    func test_select_rejectsExpiredUnknownAndDeletingCards_leavingSelectionUnchanged() {
        var selection = make([card("a"), card("b"), expired("e1")])
        selection.select("a")
        XCTAssertFalse(selection.select("e1"))
        XCTAssertFalse(selection.select("nope"))
        selection.beginDelete("b")
        XCTAssertFalse(selection.select("b"))
        XCTAssertEqual(selection.selectedId, "a")
    }

    func test_select_acceptsAUsableCard() {
        var selection = make([card("a"), card("b")])
        XCTAssertTrue(selection.select("b"))
        XCTAssertEqual(selection.selectedId, "b")
    }

    func test_remove_selectedCard_clearsSelection_andDoesNotReselect() {
        var selection = make([card("a"), card("b")])
        selection.select("a")
        selection.remove("a")
        XCTAssertNil(selection.selectedId)
        XCTAssertEqual(selection.cards.map(\.id), ["b"])
    }

    func test_remove_nonSelectedCard_keepsSelection() {
        var selection = make([card("a"), card("b")])
        selection.select("a")
        selection.remove("b")
        XCTAssertEqual(selection.selectedId, "a")
    }

    func test_remove_lastCard_makesIsEmptyTrue() {
        var selection = make([card("a")])
        XCTAssertFalse(selection.isEmpty)
        selection.remove("a")
        XCTAssertTrue(selection.isEmpty)
    }

    func test_remove_alsoEndsItsDelete() {
        var selection = make([card("a")])
        selection.beginDelete("a")
        selection.remove("a")
        XCTAssertTrue(selection.deletingIds.isEmpty)
    }

    func test_beginDelete_secondCallForSameIdReturnsFalse_andEndDeleteReenables() {
        var selection = make([card("a")])
        XCTAssertTrue(selection.beginDelete("a"))
        XCTAssertFalse(selection.beginDelete("a"))
        selection.endDelete("a")
        XCTAssertTrue(selection.beginDelete("a"))
    }

    func test_beginDelete_unknownId_returnsFalse() {
        var selection = make([card("a")])
        XCTAssertFalse(selection.beginDelete("nope"))
    }

    func test_setSelectedId_isUnchecked() {
        var selection = make([expired("e1")])
        selection.setSelectedId("e1")
        XCTAssertEqual(selection.selectedId, "e1")
        selection.setSelectedId(nil)
        XCTAssertNil(selection.selectedId)
    }

    func test_isExpired_followsTheClock() {
        let selection = make([])
        XCTAssertTrue(selection.isExpired(expired("e")))
        XCTAssertFalse(selection.isExpired(card("a")))
    }
}
