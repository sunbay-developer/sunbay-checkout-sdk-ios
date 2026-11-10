import XCTest

@testable import SunbayCheckout

final class AddressRulesTests: XCTestCase {
    private func billing(
        country: String? = "US", city: String? = "San Jose", line1: String? = "1 Main St",
        postalCode: String? = "95112"
    ) -> AddressInput {
        AddressInput(country: country, line1: line1, city: city, postalCode: postalCode)
    }

    private func shipping(
        firstName: String? = "Ada", lastName: String? = "Lovelace", phone: String? = "5551234"
    ) -> AddressInput {
        AddressInput(
            country: "US", line1: "2 Side St", city: "Austin", postalCode: "73301",
            firstName: firstName, lastName: lastName, phone: phone)
    }

    func test_sanitize_trimsAndDropsBlanks() {
        let out = AddressRules.sanitize(AddressInput(country: " US ", line1: "  ", city: "\tSan Jose\n"))
        XCTAssertEqual(out, AddressInput(country: "US", city: "San Jose"))
    }

    func test_sanitize_nilForNilAndAllBlank() {
        XCTAssertNil(AddressRules.sanitize(nil))
        XCTAssertNil(AddressRules.sanitize(AddressInput(country: " ", line1: "")))
    }

    func test_billingComplete() {
        XCTAssertTrue(AddressRules.isComplete(.billing, billing()))
        XCTAssertFalse(AddressRules.isComplete(.billing, nil))
        XCTAssertFalse(AddressRules.isComplete(.billing, billing(country: nil)))
        XCTAssertFalse(AddressRules.isComplete(.billing, billing(city: " ")))
        XCTAssertFalse(AddressRules.isComplete(.billing, billing(line1: nil)))
        XCTAssertFalse(AddressRules.isComplete(.billing, billing(postalCode: "  ")))
    }

    func test_shippingNeedsNamesAndPhone() {
        XCTAssertTrue(AddressRules.isComplete(.shipping, shipping()))
        XCTAssertFalse(AddressRules.isComplete(.shipping, shipping(firstName: nil)))
        XCTAssertFalse(AddressRules.isComplete(.shipping, shipping(lastName: nil)))
        XCTAssertFalse(AddressRules.isComplete(.shipping, shipping(phone: nil)))
        XCTAssertFalse(AddressRules.isComplete(.shipping, billing()))
    }

    func test_hasDraftContent_ignoresCountry() {
        XCTAssertFalse(AddressRules.hasDraftContent(nil))
        XCTAssertFalse(AddressRules.hasDraftContent(AddressInput(country: "US")))
        XCTAssertTrue(AddressRules.hasDraftContent(AddressInput(country: "US", postalCode: "95112")))
    }

    func test_customerName_prefersShippingThenBilling() {
        let ship = shipping()
        let bill = AddressInput(firstName: "Grace", lastName: "Hopper")
        XCTAssertEqual(AddressRules.customerName(billing: bill, shipping: ship), "Ada Lovelace")
        XCTAssertEqual(AddressRules.customerName(billing: bill, shipping: nil), "Grace Hopper")
        XCTAssertEqual(AddressRules.customerName(billing: bill, shipping: shipping(lastName: nil)), "Grace Hopper")
        XCTAssertNil(AddressRules.customerName(billing: AddressInput(firstName: "Grace"), shipping: nil))
        XCTAssertNil(AddressRules.customerName(billing: nil, shipping: nil))
    }
}
