import XCTest
@testable import SunbayCheckout

/// Runs the contract's test vectors (`docs/card-rules-contract.md` §6) against the **bundled** rules
/// document, i.e. the HPP document the SDK actually ships.
final class CardRulesContractVectorsTests: XCTestCase {
    private func bundled() throws -> CardRuleSet {
        try XCTUnwrap(CardRulesProvider.bundled, "the bundled rules document must parse")
    }

    func test_bundled_parsesAndIsNotTheDraft() throws {
        let set = try bundled()
        XCTAssertNotEqual(set.version, "draft-bundled-1")
        XCTAssertEqual(
            Set(set.brands.map(\.scheme)),
            ["visa", "mastercard", "amex", "discover", "jcb", "unionpay", "dinersclub"])
    }

    func test_formatting() throws {
        let set = try bundled()
        let rows: [(String?, String, String)] = [
            ("visa", "4242424242424242", "4242 4242 4242 4242"),
            ("visa", "4242424242424242424", "4242 4242 4242 4242 424"),
            ("amex", "378282246310005", "3782 822463 10005"),
            ("dinersclub", "36227206271667", "3622 720627 1667"),
            ("dinersclub", "3622720627166712", "3622 7206 2716 6712"),
            ("unionpay", "6222021234567890123", "6222 0212 3456 7890 123"),
            (nil, "12345678901234567", "1234 5678 9012 3456 7"),
        ]
        for (scheme, digits, expected) in rows {
            let rules = set.rules(forScheme: scheme)
            XCTAssertEqual(PANFormatter.format(digits, rules: rules), expected, "\(scheme ?? "generic") \(digits)")
        }
    }

    func test_prefixMatching() throws {
        let set = try bundled()
        let rows: [(String, String?)] = [
            ("4", "visa"), ("34", "amex"), ("37", "amex"),
            ("51", "mastercard"), ("55", "mastercard"), ("2221", "mastercard"), ("2720", "mastercard"),
            ("3", nil), ("36", "dinersclub"), ("6011", "discover"), ("3528", "jcb"), ("620", "unionpay"),
        ]
        for (typed, expected) in rows {
            XCTAssertEqual(set.detectScheme(digits: typed), expected, "typed \(typed)")
        }
    }

    func test_autoAdvance() throws {
        let set = try bundled()
        XCTAssertEqual(set.rules(forScheme: "amex").autoAdvanceLength, 15)
        XCTAssertEqual(set.rules(forScheme: "mastercard").autoAdvanceLength, 16)
        XCTAssertNil(set.rules(forScheme: nil).autoAdvanceLength)
    }

    func test_discoverAndUnionpayPrefixesDoNotOverlap() throws {
        let set = try bundled()
        // UnionPay's 622126–622925 range overlaps Discover's legacy range on paper; the shipped patterns
        // must send these to UnionPay and never to Discover.
        for typed in ["622126", "622925", "6221", "62", "81", "8171"] {
            XCTAssertEqual(set.detectScheme(digits: typed), "unionpay", "typed \(typed)")
        }
        for typed in ["6011", "644", "649", "65"] {
            XCTAssertEqual(set.detectScheme(digits: typed), "discover", "typed \(typed)")
        }
    }

    func test_securityCodeHints() throws {
        let set = try bundled()
        XCTAssertEqual(set.rules(forScheme: "amex").cvvPlaceholder, "1234")
        XCTAssertEqual(set.rules(forScheme: "visa").cvvPlaceholder, "123")
        XCTAssertEqual(set.rules(forScheme: "visa").cvvName, "CVV")
    }
}
