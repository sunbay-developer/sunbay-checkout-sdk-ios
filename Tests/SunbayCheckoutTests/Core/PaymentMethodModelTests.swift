import XCTest

@testable import SunbayCheckout

final class PaymentMethodModelTests: XCTestCase {
    private func entry(_ method: String, _ type: String = "CARD") -> MethodEntry {
        MethodEntry(method: method, type: type, name: method, logoURL: nil)
    }

    private let visa = MethodEntry(method: "VISA", type: "CARD", name: "Visa", logoURL: nil)
    private let amex = MethodEntry(method: "AMEX", type: "CARD", name: "Amex", logoURL: nil)
    private let apple = MethodEntry(method: "APPLE_PAY", type: "E_WALLET", name: "Apple Pay", logoURL: nil)

    private var all: [MethodEntry] { [visa, apple, amex] }

    func test_logicalKey_cardTypeIsCard_otherwiseMethod() {
        XCTAssertEqual(PaymentMethodModel.logicalKey(visa), "CARD")
        XCTAssertEqual(PaymentMethodModel.logicalKey(apple), "APPLE_PAY")
    }

    func test_emptyFilter_returnsInput() {
        let result = PaymentMethodModel.apply(PaymentMethodFilter(), to: all)
        XCTAssertEqual(result.entries, all)
        XCTAssertTrue(result.ignored.isEmpty)
    }

    func test_hideCard_removesEveryCardEntry() {
        let result = PaymentMethodModel.apply(PaymentMethodFilter(hide: ["CARD"]), to: all)
        XCTAssertEqual(result.entries, [apple])
        XCTAssertTrue(result.ignored.isEmpty)
    }

    func test_hideRawMethod_removesOneBrandWithoutIgnoring() {
        let result = PaymentMethodModel.apply(PaymentMethodFilter(hide: ["AMEX"]), to: all)
        XCTAssertEqual(result.entries, [visa, apple])
        XCTAssertTrue(result.ignored.isEmpty)
    }

    func test_unknownLowercaseEmptyAndDuplicate_areIgnoredOnceEach() {
        let filter = PaymentMethodFilter(hide: ["applePay", "", "applePay", "NOPE"], order: ["NOPE"])
        let result = PaymentMethodModel.apply(filter, to: all)
        XCTAssertEqual(result.entries, all)
        XCTAssertEqual(result.ignored.map(\.identifier), ["applePay", "", "NOPE"])
        for item in result.ignored {
            for id in ["CARD", "VISA", "APPLE_PAY", "AMEX"] { XCTAssertTrue(item.reason.contains(id)) }
        }
    }

    func test_hideWinsOverOrder_andIsNotIgnored() {
        let result = PaymentMethodModel.apply(PaymentMethodFilter(hide: ["AMEX"], order: ["AMEX"]), to: all)
        XCTAssertEqual(result.entries, [visa, apple])
        XCTAssertTrue(result.ignored.isEmpty)
    }

    func test_order_isStable_andUnmatchedIsIgnored() {
        let result = PaymentMethodModel.apply(PaymentMethodFilter(order: ["GOOGLE_PAY", "CARD"]), to: all)
        XCTAssertEqual(result.entries, [visa, amex, apple])
        XCTAssertEqual(result.ignored.map(\.identifier), ["GOOGLE_PAY"])
    }

    func test_everythingHidden_isEmpty() {
        let result = PaymentMethodModel.apply(PaymentMethodFilter(hide: ["CARD", "APPLE_PAY"]), to: all)
        XCTAssertTrue(result.entries.isEmpty)
    }

    func test_randomFilters_yieldSubPermutationAndUniqueIgnored() {
        let pool = ["CARD", "VISA", "AMEX", "APPLE_PAY", "", "x", "card"]
        var generator = SystemRandomNumberGenerator()
        for _ in 0..<200 {
            let hide = (0..<Int.random(in: 0...4, using: &generator)).map { _ in PaymentMethodID(rawValue: pool.randomElement()!) }
            let order = (0..<Int.random(in: 0...4, using: &generator)).map { _ in PaymentMethodID(rawValue: pool.randomElement()!) }
            let result = PaymentMethodModel.apply(PaymentMethodFilter(hide: hide, order: order), to: all)
            var remaining = all
            for e in result.entries {
                guard let index = remaining.firstIndex(of: e) else { return XCTFail("result is not a sub-permutation") }
                remaining.remove(at: index)
            }
            let ids = result.ignored.map(\.identifier)
            XCTAssertEqual(ids.count, Set(ids).count)
        }
    }
}
