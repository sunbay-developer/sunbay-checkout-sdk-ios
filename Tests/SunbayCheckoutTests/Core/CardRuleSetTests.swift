import XCTest
@testable import SunbayCheckout

final class CardRuleSetTests: XCTestCase {
    private func document(
        schemaVersion: Int = 1, genericGroups: String = "[4,4,4,4]", brands: String = visaBrand
    ) -> Data {
        Data(
            """
            {"schemaVersion":\(schemaVersion),"version":"t","generic":{"groups":\(genericGroups),\
            "minLength":12,"maxLength":19,"cvv":{"name":"CVC","sizes":[3,4]}},"brands":[\(brands)]}
            """.utf8)
    }

    private static let visaBrand = brand(scheme: "visa", patterns: "[4]")

    private static func brand(
        scheme: String, patterns: String, groups: String = "[4,4,4,4]", cvvSizes: String = "[3]"
    ) -> String {
        """
        {"scheme":"\(scheme)","displayName":"\(scheme.capitalized)","patterns":\(patterns),\
        "lengths":[16],"groups":\(groups),"cvv":{"name":"CVV","sizes":\(cvvSizes)}}
        """
    }

    func test_parse_acceptsMinimalValidDocument() {
        let set = CardRuleSet.parse(document())
        XCTAssertEqual(set?.brands.map(\.scheme), ["visa"])
    }

    func test_parse_rejectsUnknownSchemaVersion() {
        XCTAssertNil(CardRuleSet.parse(document(schemaVersion: 2)))
    }

    func test_parse_rejectsOversizedDocument() {
        let padding = String(repeating: " ", count: CardRuleSet.maxDocumentBytes)
        let data = document() + Data(padding.utf8)
        XCTAssertNil(CardRuleSet.parse(data))
    }

    func test_parse_rejectsBadGroups() {
        XCTAssertNil(CardRuleSet.parse(document(genericGroups: "[20]")))
        XCTAssertNil(
            CardRuleSet.parse(document(brands: Self.brand(scheme: "visa", patterns: "[4]", groups: "[10,10]"))))
    }

    func test_parse_rejectsBadCvvSizes() {
        XCTAssertNil(
            CardRuleSet.parse(document(brands: Self.brand(scheme: "visa", patterns: "[4]", cvvSizes: "[5]"))))
    }

    func test_parse_rejectsMoreThan64Brands() {
        let many = (0..<65).map { Self.brand(scheme: "b\($0)", patterns: "[\($0 + 1)]") }.joined(separator: ",")
        XCTAssertNil(CardRuleSet.parse(document(brands: many)))
    }

    func test_parse_rejectsGarbage() {
        XCTAssertNil(CardRuleSet.parse(Data("not json".utf8)))
    }

    func test_parse_mapsDinersKeyToDinersclub() throws {
        let set = try XCTUnwrap(
            CardRuleSet.parse(document(brands: Self.brand(scheme: "diners", patterns: "[36]"))))
        XCTAssertEqual(set.brands.map(\.scheme), ["dinersclub"])
        XCTAssertEqual(set.rules(forScheme: "dinersclub").displayName, "Diners")
    }

    func test_parse_dinersKeyIsCaseInsensitive() throws {
        let set = try XCTUnwrap(
            CardRuleSet.parse(document(brands: Self.brand(scheme: "DINERS", patterns: "[36]"))))
        XCTAssertEqual(set.brands.map(\.scheme), ["dinersclub"])
    }

    func test_detectScheme_dinersPrefixResolvesToDinersclub() throws {
        let set = try XCTUnwrap(
            CardRuleSet.parse(document(brands: Self.brand(scheme: "diners", patterns: "[36]"))))
        XCTAssertEqual(set.detectScheme(digits: "36"), "dinersclub")
    }

    func test_parse_keepsDinersclubKeyUnchanged() throws {
        let set = try XCTUnwrap(
            CardRuleSet.parse(document(brands: Self.brand(scheme: "dinersclub", patterns: "[36]"))))
        XCTAssertEqual(set.brands.map(\.scheme), ["dinersclub"])
    }
}
