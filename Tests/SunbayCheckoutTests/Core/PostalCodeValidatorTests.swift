import XCTest
@testable import SunbayCheckout

final class PostalCodeValidatorTests: XCTestCase {
    private static let us = "^[0-9]{5}(-[0-9]{4})?$"

    private func config(required: Bool, pattern: String?) -> AddressFieldConfig {
        AddressFieldConfig(type: .postalCode, required: required, pattern: pattern, label: "", placeholder: "")
    }

    func testNilConfigIsAlwaysValid() {
        XCTAssertEqual(PostalCodeValidator.validate(nil, config: nil), .valid)
        XCTAssertEqual(PostalCodeValidator.validate("", config: nil), .valid)
        XCTAssertEqual(PostalCodeValidator.validate("abc", config: nil), .valid)
    }

    func testRequiredWithoutPattern() {
        let c = config(required: true, pattern: nil)
        XCTAssertEqual(PostalCodeValidator.validate("", config: c), .required)
        XCTAssertEqual(PostalCodeValidator.validate(nil, config: c), .required)
        XCTAssertEqual(PostalCodeValidator.validate("  ", config: c), .required)
        XCTAssertEqual(PostalCodeValidator.validate("anything", config: c), .valid)
    }

    func testOptionalWithPattern() {
        let c = config(required: false, pattern: Self.us)
        XCTAssertEqual(PostalCodeValidator.validate("", config: c), .valid)
        XCTAssertEqual(PostalCodeValidator.validate("94103", config: c), .valid)
        XCTAssertEqual(PostalCodeValidator.validate(" 94103 ", config: c), .valid)
        XCTAssertEqual(PostalCodeValidator.validate("9410", config: c), .invalidFormat)
        XCTAssertEqual(PostalCodeValidator.validate("94103x", config: c), .invalidFormat)
    }

    func testRequiredWithPattern() {
        let c = config(required: true, pattern: Self.us)
        XCTAssertEqual(PostalCodeValidator.validate("", config: c), .required)
        XCTAssertEqual(PostalCodeValidator.validate("abcde", config: c), .invalidFormat)
    }

    func testUncompilablePatternIsValid() {
        let c = config(required: false, pattern: "([unclosed")
        XCTAssertEqual(PostalCodeValidator.validate("x", config: c), .valid)
    }

    func testAlternationMatchesWholeValue() {
        let c = config(required: false, pattern: "[0-9]{5}|[0-9]{5}-[0-9]{4}")
        XCTAssertEqual(PostalCodeValidator.validate("12345-6789", config: c), .valid)
        XCTAssertEqual(PostalCodeValidator.validate("12345-67", config: c), .invalidFormat)
    }

    func testUnanchoredPatternMustMatchWholeValue() {
        let c = config(required: false, pattern: "[0-9]{5}")
        XCTAssertEqual(PostalCodeValidator.validate("123456", config: c), .invalidFormat)
    }
}
