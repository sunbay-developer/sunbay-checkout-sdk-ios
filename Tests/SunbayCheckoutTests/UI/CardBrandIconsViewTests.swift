#if canImport(UIKit)
    import UIKit
    import XCTest

    @testable import SunbayCheckout

    @MainActor
    final class CardBrandIconsViewTests: XCTestCase {
        private static func pngData() -> Data {
            UIGraphicsImageRenderer(size: CGSize(width: 4, height: 4)).pngData { ctx in
                UIColor.blue.setFill()
                ctx.fill(CGRect(x: 0, y: 0, width: 4, height: 4))
            }
        }

        private func item(_ scheme: String, fail: Bool = false) -> CardBrandItem {
            CardBrandItem(
                scheme: scheme, name: scheme,
                logoURL: URL(string: "https://cdn.example.com/\(fail ? "fail-" : "")\(scheme).png")!)
        }

        private func makeView(_ items: [CardBrandItem]) async -> CardBrandIconsView {
            let data = Self.pngData()
            let loader = CardBrandLogoLoader(fetch: { url in
                if url.lastPathComponent.hasPrefix("fail-") { throw URLError(.cannotConnectToHost) }
                return data
            })
            let view = CardBrandIconsView(appearance: .resolve(.default), loader: loader)
            view.configure(items: items)
            view.update(isEmpty: true, scheme: nil)
            await settle(view, expectedResolved: items.count)
            return view
        }

        /// Waits until every item's logo load has finished (success or failure).
        private func settle(_ view: CardBrandIconsView, expectedResolved: Int) async {
            for _ in 0..<100 where view.resolvedCountForTest < expectedResolved {
                try? await Task.sleep(nanoseconds: 10_000_000)
            }
        }

        func test_emptyShowsFirstTwoPlusRotatingSlot() async {
            let view = await makeView([item("visa"), item("mastercard"), item("amex"), item("jcb")])
            XCTAssertEqual(view.visibleSchemesForTest, ["visa", "mastercard", "amex"])
            XCTAssertFalse(view.showsFallbackForTest)
        }

        func test_advanceCyclesThroughRemainingBrands() async {
            let view = await makeView([item("visa"), item("mastercard"), item("amex"), item("jcb")])
            view.advanceForTest()
            XCTAssertEqual(view.visibleSchemesForTest, ["visa", "mastercard", "jcb"])
            view.advanceForTest()
            XCTAssertEqual(view.visibleSchemesForTest, ["visa", "mastercard", "amex"])
        }

        func test_twoOrFewerBrandsShowAllAndDoNotRotate() async {
            let view = await makeView([item("visa"), item("mastercard")])
            XCTAssertEqual(view.visibleSchemesForTest, ["visa", "mastercard"])
            XCTAssertFalse(view.isRotatingForTest)
        }

        func test_typingShowsOnlyMatchedBrand() async {
            let view = await makeView([item("visa"), item("mastercard"), item("amex")])
            view.update(isEmpty: false, scheme: "visa")
            XCTAssertEqual(view.visibleSchemesForTest, ["visa"])
            XCTAssertFalse(view.isRotatingForTest)
        }

        func test_typingUnrecognizedShowsNothing() async {
            let view = await makeView([item("visa"), item("mastercard"), item("amex")])
            view.update(isEmpty: false, scheme: nil)
            XCTAssertEqual(view.visibleSchemesForTest, [])
            XCTAssertFalse(view.showsFallbackForTest)
        }

        func test_unknownSchemeNotInSessionShowsNothing() async {
            let view = await makeView([item("visa"), item("mastercard")])
            view.update(isEmpty: false, scheme: "mir")
            XCTAssertEqual(view.visibleSchemesForTest, [])
        }

        func test_noItemsShowsFallbackWhenEmpty() async {
            let view = await makeView([])
            XCTAssertTrue(view.showsFallbackForTest)
            XCTAssertEqual(view.visibleSchemesForTest, [])
        }

        func test_allLogosFailShowTextBadges() async {
            let view = await makeView([item("visa", fail: true), item("amex", fail: true)])
            XCTAssertFalse(view.showsFallbackForTest)
            XCTAssertEqual(view.visibleSchemesForTest, ["visa", "amex"])
        }

        func test_failedLogoFallsBackToBadgeInOrder() async {
            let view = await makeView([item("visa", fail: true), item("mastercard"), item("amex")])
            XCTAssertEqual(view.visibleSchemesForTest, ["visa", "mastercard", "amex"])
        }

        func test_clearingBackToEmptyRestoresCarousel() async {
            let view = await makeView([item("visa"), item("mastercard"), item("amex")])
            view.update(isEmpty: false, scheme: "visa")
            view.update(isEmpty: true, scheme: nil)
            XCTAssertEqual(view.visibleSchemesForTest, ["visa", "mastercard", "amex"])
        }

        func test_rotationRunsOnlyWhileOnScreenAndEmpty() async {
            let view = await makeView([item("visa"), item("mastercard"), item("amex")])
            XCTAssertFalse(view.isRotatingForTest, "no timer without a window")
            let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 320, height: 480))
            window.addSubview(view)
            window.makeKeyAndVisible()
            XCTAssertTrue(view.isRotatingForTest)
            view.update(isEmpty: false, scheme: "visa")
            XCTAssertFalse(view.isRotatingForTest)
            view.update(isEmpty: true, scheme: nil)
            XCTAssertTrue(view.isRotatingForTest)
            view.removeFromSuperview()
            XCTAssertFalse(view.isRotatingForTest)
        }
    }
#endif
