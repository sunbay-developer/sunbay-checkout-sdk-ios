#if canImport(UIKit)
    import UIKit
    import XCTest

    @testable import SunbayCheckout

    /// Unit tests for `CardFormView`'s `cardInput` assembly (absorbed from the former `CardField`).
    ///
    /// UIKit is iOS-only. On the macOS host (`swift test`) this whole file is excluded by
    /// `#if canImport(UIKit)` and is vacuous; the real RED/GREEN requires building against the iOS
    /// Simulator SDK. The two cases mirror the former `CardField.cardInput` rules: `nil` when any of
    /// PAN / expiry / CVC is empty, and a populated `CardInput` (with the expiry split on `/`) when all
    /// three are filled.
    @MainActor
    final class CardFormViewTests: XCTestCase {
        func test_cardInputNilWhenIncomplete() {
            let v = CardFormView(appearance: .resolve(.default), localize: { $0 })
            XCTAssertNil(v.cardInput)
        }

        func test_cardInputAssemblesWhenComplete() {
            let v = CardFormView(appearance: .resolve(.default), localize: { $0 })
            v.setFieldsForTest(pan: "4242424242424242", expiry: "08/99", cvv: "123")
            XCTAssertEqual(v.cardInput?.cardNumber, "4242424242424242")
            XCTAssertEqual(v.cardInput?.expiryMonth, "08")
            XCTAssertEqual(v.cardInput?.expiryYear, "2099")
        }

        // MARK: - Brand icons

        private func makeForm(schemes: [String]) async -> CardFormView {
            let png = UIGraphicsImageRenderer(size: CGSize(width: 4, height: 4)).pngData { ctx in
                UIColor.green.setFill()
                ctx.fill(CGRect(x: 0, y: 0, width: 4, height: 4))
            }
            let items = schemes.map {
                CardBrandItem(scheme: $0, name: $0, logoURL: URL(string: "https://cdn.example.com/\($0).png")!)
            }
            let form = CardFormView(
                appearance: .resolve(.default), localize: { $0 }, brandItems: items,
                logoLoader: CardBrandLogoLoader(fetch: { _ in png }))
            for _ in 0..<100 where form.brandLogosResolvedForTest < items.count {
                try? await Task.sleep(nanoseconds: 10_000_000)
            }
            return form
        }

        func test_emptyPANShowsBrandCarouselItems() async {
            let form = await makeForm(schemes: ["visa", "mastercard", "amex", "jcb"])
            XCTAssertEqual(form.brandSchemesForTest, ["visa", "mastercard", "amex"])
        }

        func test_typingVisaPrefixShowsOnlyVisa() async {
            let form = await makeForm(schemes: ["visa", "mastercard", "amex"])
            form.typePANForTest("4")
            XCTAssertEqual(form.brandSchemesForTest, ["visa"])
        }

        func test_backendSchemeOverridesLocalGuess() async {
            let form = await makeForm(schemes: ["visa", "mastercard", "amex"])
            form.typePANForTest("4")
            form.setBackendScheme("mastercard")
            XCTAssertEqual(form.brandSchemesForTest, ["mastercard"])
            form.setBackendScheme(nil)
            XCTAssertEqual(form.brandSchemesForTest, ["visa"])
        }

        func test_clearingPANRestoresCarousel() async {
            let form = await makeForm(schemes: ["visa", "mastercard", "amex"])
            form.typePANForTest("4")
            form.typePANForTest("")
            XCTAssertEqual(form.brandSchemesForTest, ["visa", "mastercard", "amex"])
        }

        func test_cvvIconPresent() {
            let v = CardFormView(appearance: .resolve(.default), localize: { $0 })
            XCTAssertTrue(v.hasCVVIconForTest)
        }
    }
#endif
