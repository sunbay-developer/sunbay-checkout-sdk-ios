import XCTest
@testable import Showcase

final class CartStoreTests: XCTestCase {
    func testAddAccumulatesTotal() {
        let cart = CartStore()
        let a = Catalog.products[0]
        let b = Catalog.products[1]
        cart.add(a)
        cart.add(a)
        cart.add(b)
        XCTAssertEqual(cart.totalMinor, a.priceMinor * 2 + b.priceMinor)
        XCTAssertEqual(cart.itemCount, 3)
        XCTAssertEqual(cart.lines.count, 2)
        XCTAssertFalse(cart.isEmpty)
    }

    func testSetQuantityZeroRemovesLine() {
        let cart = CartStore()
        let a = Catalog.products[0]
        cart.add(a)
        cart.setQuantity(a, 3)
        XCTAssertEqual(cart.quantities[a.id], 3)
        cart.setQuantity(a, 0)
        XCTAssertNil(cart.quantities[a.id])
        XCTAssertTrue(cart.isEmpty)
    }

    func testClearEmptiesCart() {
        let cart = CartStore()
        cart.add(Catalog.products[0])
        cart.clear()
        XCTAssertTrue(cart.isEmpty)
        XCTAssertEqual(cart.totalMinor, 0)
    }

    func testOrderNumberFormat() {
        let n = CartStore.makeOrderNumber()
        XCTAssertNotNil(n.range(of: "^SB-\\d{6}$", options: .regularExpression))
    }

    func testCatalogHasFiveUniqueProducts() {
        XCTAssertEqual(Catalog.products.count, 5)
        XCTAssertEqual(Set(Catalog.products.map(\.id)).count, 5)
    }
}

final class MoneyFormatTests: XCTestCase {
    func testFormatUSD() {
        XCTAssertEqual(formatUSD(minor: 14_900), "$149.00")
        XCTAssertEqual(formatUSD(minor: 1_205), "$12.05")
    }
}
