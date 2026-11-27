import XCTest

@testable import SunbayCheckout

/// The local PAN heuristics (the scan parser's plausibility check and the card form's completeness fallback)
/// exist only as a last resort when no brand rules match. They must never accept a length that the bundled
/// rules document rejects for the brand the rules would detect.
final class CardHeuristicsAgreeWithRulesTests: XCTestCase {
    /// One representative Luhn-valid number prefix per brand family.
    private static let prefixes = [
        "4", "4111", "51", "55", "2221", "2720", "34", "37", "6011", "65", "644", "35", "3528", "62", "81",
        "30", "36", "38", "39",
    ]

    /// Every Luhn-valid number of lengths 13...19 built from each prefix.
    static func candidates() -> [String] {
        var result: [String] = []
        for prefix in prefixes {
            for length in 13...19 {
                let body = prefix + String(repeating: "1", count: length - prefix.count - 1)
                for check in 0...9 where CardScanParser.luhnValid(body + String(check)) {
                    result.append(body + String(check))
                }
            }
        }
        return result
    }

    private func bundled() throws -> CardRuleSet {
        try XCTUnwrap(CardRulesProvider.bundled, "the bundled rules document must parse")
    }

    /// The lengths the rules allow for the detected brand, or nil when no brand matches.
    private func allowedLengths(_ digits: String, _ set: CardRuleSet) -> [Int]? {
        guard let scheme = set.detectScheme(digits: digits),
            let brand = set.brands.first(where: { $0.scheme == scheme })
        else { return nil }
        return brand.lengths
    }

    func test_scanPlausibility_neverAcceptsALengthTheRulesReject() throws {
        let set = try bundled()
        var accepted = 0
        for digits in Self.candidates() where CardScanParser.isPlausiblePAN(digits, rules: set) {
            accepted += 1
            // A number the rules cannot attribute to a brand is outside this check.
            guard let lengths = allowedLengths(digits, set) else { continue }
            XCTAssertTrue(
                lengths.contains(digits.count),
                "scan accepts \(digits.count) digits for \(set.detectScheme(digits: digits) ?? "?"), rules allow \(lengths)")
        }
        XCTAssertGreaterThan(accepted, 0, "the candidate set must exercise the heuristic")
    }

    /// Without rules the parser keeps its local heuristics (the last-resort fallback).
    func test_scanPlausibility_withoutRulesKeepsTheFallback() {
        XCTAssertTrue(CardScanParser.isPlausiblePAN("4111111111111111"))
        XCTAssertTrue(CardScanParser.isPlausiblePAN("378282246310005"))
        XCTAssertFalse(CardScanParser.isPlausiblePAN("4111111111111112"), "Luhn still applies")
    }

    func test_scanPlausibility_withRulesAcceptsEachBrandsRealLengths() throws {
        let set = try bundled()
        for pan in ["4111111111111111", "5555555555554444", "378282246310005", "6011111111111117",
                    "3530111333300000", "6200000000000005", "30569309025904"] {
            XCTAssertTrue(CardScanParser.isPlausiblePAN(pan, rules: set), pan)
        }
    }
}

#if canImport(UIKit)
    extension CardHeuristicsAgreeWithRulesTests {
        func test_completePANFallback_neverAcceptsALengthTheRulesReject() throws {
            let set = try bundled()
            var accepted = 0
            for digits in Self.candidates() where CardFormView.isCompletePAN(digits) {
                accepted += 1
                guard let lengths = allowedLengths(digits, set) else { continue }
                XCTAssertTrue(
                    lengths.contains(digits.count),
                    "form fallback completes \(digits.count) digits for \(set.detectScheme(digits: digits) ?? "?"), rules allow \(lengths)")
            }
            XCTAssertGreaterThan(accepted, 0, "the candidate set must exercise the heuristic")
        }
    }
#endif
