import XCTest
@testable import SunbayCheckout

final class SavedCardExpiryTests: XCTestCase {
    private let calendar: Calendar = {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "UTC")!
        return c
    }()

    private func date(_ year: Int, _ month: Int, _ day: Int) -> Date {
        calendar.date(from: DateComponents(year: year, month: month, day: day))!
    }

    private func card(_ id: String, _ month: Int, _ year: Int) -> SavedCard {
        SavedCard(id: id, brand: "visa", last4: "4242", expMonth: month, expYear: year)
    }

    func testCardIsValidThroughItsExpiryMonth() {
        let now = date(2026, 11, 30)
        XCTAssertFalse(SavedCardExpiry.isExpired(card("a", 11, 2026), at: now, calendar: calendar))
        XCTAssertFalse(SavedCardExpiry.isExpired(card("b", 12, 2026), at: now, calendar: calendar))
        XCTAssertFalse(SavedCardExpiry.isExpired(card("c", 1, 2027), at: now, calendar: calendar))
    }

    func testCardIsExpiredAfterItsExpiryMonth() {
        let now = date(2026, 11, 1)
        XCTAssertTrue(SavedCardExpiry.isExpired(card("a", 10, 2026), at: now, calendar: calendar))
        XCTAssertTrue(SavedCardExpiry.isExpired(card("b", 12, 2025), at: now, calendar: calendar))
    }

    func testUsableFirstKeepsOrderWithinGroups() {
        let now = date(2026, 11, 10)
        let cards = [card("old1", 1, 2025), card("ok1", 1, 2028), card("old2", 10, 2026), card("ok2", 11, 2026)]
        let ordered = SavedCardExpiry.usableFirst(cards, at: now, calendar: calendar).map(\.id)
        XCTAssertEqual(ordered, ["ok1", "ok2", "old1", "old2"])
    }
}
