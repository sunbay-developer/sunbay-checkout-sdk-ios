import XCTest

@testable import SunbayCheckout

final class CardValidationTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)  // Jan 2027

    private func issue(
        pan: String = "4242 4242 4242 4242", expiry: String = "12/99", cvv: String = "123",
        rules: CardRules = .generic
    ) -> CardValidationIssue? {
        CardValidation.firstIssue(pan: pan, expiry: expiry, cvv: cvv, rules: rules, now: now)
    }

    func test_validEntryHasNoIssue() { XCTAssertNil(issue()) }

    func test_numberIssues() {
        XCTAssertEqual(issue(pan: ""), .numberEmpty)
        XCTAssertEqual(issue(pan: "4242 4242"), .numberIncomplete)
        XCTAssertEqual(issue(pan: "4242 4242 4242 4241"), .numberInvalid)
    }

    func test_expiryIssues() {
        XCTAssertEqual(issue(expiry: ""), .expiryEmpty)
        XCTAssertEqual(issue(expiry: "1"), .expiryIncomplete)
        XCTAssertEqual(issue(expiry: "12/2"), .expiryIncomplete)
        XCTAssertEqual(issue(expiry: "13/30"), .expiryMonthInvalid)
        XCTAssertEqual(issue(expiry: "01/20"), .expiryPast)
    }

    func test_cvcIssues() {
        XCTAssertEqual(issue(cvv: ""), .cvcEmpty)
        XCTAssertEqual(issue(cvv: "12"), .cvcIncomplete)
        XCTAssertNil(issue(cvv: "1234"))
    }

    func test_firstIssueFollowsFieldOrder() {
        XCTAssertEqual(issue(pan: "", expiry: "", cvv: ""), .numberEmpty)
        XCTAssertEqual(issue(expiry: "", cvv: ""), .expiryEmpty)
    }

    func test_everyIssueHasADistinctMessageKey() {
        let all: [CardValidationIssue] = [
            .numberEmpty, .numberIncomplete, .numberInvalid, .expiryEmpty, .expiryIncomplete,
            .expiryMonthInvalid, .expiryPast, .cvcEmpty, .cvcIncomplete,
        ]
        XCTAssertEqual(Set(all.map(\.messageKey)).count, all.count)
        for issue in all { XCTAssertTrue(SunbayUIStringKeys.all.contains(issue.messageKey)) }
    }
}
