import XCTest

@testable import SunbayCheckout

final class CardBrandItemTests: XCTestCase {
    private func entry(_ method: String, type: String = "CARD", logo: String? = nil) -> MethodEntry {
        MethodEntry(method: method, type: type, name: method.capitalized, logoURL: logo)
    }

    func test_items_keepsOnlyCardEntriesWithHTTPSLogo() {
        let items = CardBrandItem.items(from: [
            entry("VISA", logo: "https://cdn.example.com/visa.png"),
            entry("APPLE_PAY", type: "E_WALLET", logo: "https://cdn.example.com/apple.png"),
            entry("AMEX", logo: nil),
            entry("JCB", logo: "http://cdn.example.com/jcb.png"),
            entry("MASTERCARD", logo: "not a url"),
        ])
        XCTAssertEqual(items.map(\.scheme), ["visa"])
    }

    func test_items_dedupesBySchemeKeepingFirst() {
        let items = CardBrandItem.items(from: [
            entry("VISA", logo: "https://cdn.example.com/a.png"),
            entry("visa", logo: "https://cdn.example.com/b.png"),
        ])
        XCTAssertEqual(items.count, 1)
        XCTAssertEqual(items[0].logoURL.absoluteString, "https://cdn.example.com/a.png")
    }

    func test_items_preservesBackendOrder() {
        let items = CardBrandItem.items(from: [
            entry("MASTERCARD", logo: "https://cdn.example.com/m.png"),
            entry("VISA", logo: "https://cdn.example.com/v.png"),
            entry("AMEX", logo: "https://cdn.example.com/x.png"),
        ])
        XCTAssertEqual(items.map(\.scheme), ["mastercard", "visa", "amex"])
    }

    func test_item_matchingIsCaseInsensitive() {
        let items = CardBrandItem.items(from: [entry("VISA", logo: "https://cdn.example.com/v.png")])
        XCTAssertEqual(CardBrandItem.item(matching: "Visa ", in: items)?.scheme, "visa")
    }

    func test_item_matchingDinersclub() {
        let items = CardBrandItem.items(from: [entry("DINERSCLUB", logo: "https://cdn.example.com/d.png")])
        XCTAssertEqual(CardBrandItem.item(matching: "dinersclub", in: items)?.scheme, "dinersclub")
    }

    func test_item_nilOrUnknownSchemeReturnsNil() {
        let items = CardBrandItem.items(from: [entry("VISA", logo: "https://cdn.example.com/v.png")])
        XCTAssertNil(CardBrandItem.item(matching: nil, in: items))
        XCTAssertNil(CardBrandItem.item(matching: "", in: items))
        XCTAssertNil(CardBrandItem.item(matching: "mir", in: items))
    }
}
