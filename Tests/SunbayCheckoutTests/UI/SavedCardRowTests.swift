#if canImport(UIKit)
    import UIKit
    import XCTest

    @testable import SunbayCheckout

    @MainActor
    final class SavedCardRowTests: XCTestCase {
        private let logoURL = URL(string: "https://cdn.example.com/mastercard.png")!

        private static func pngData() -> Data {
            UIGraphicsImageRenderer(size: CGSize(width: 30, height: 24)).pngData { ctx in
                UIColor.orange.setFill()
                ctx.fill(CGRect(x: 0, y: 0, width: 30, height: 24))
            }
        }

        private func card(logo: URL?) -> SavedCard {
            SavedCard(id: "pm_1", brand: "MASTERCARD", last4: "4444", expMonth: 12, expYear: 2030, logoUrl: logo)
        }

        private func layout(_ row: SavedCardRow) {
            row.frame = CGRect(x: 0, y: 0, width: 358, height: 52)
            row.setNeedsLayout()
            row.layoutIfNeeded()
        }

        private func spin(until condition: () -> Bool, timeout: TimeInterval = 2) {
            let deadline = Date().addingTimeInterval(timeout)
            while !condition(), Date() < deadline {
                RunLoop.main.run(until: Date().addingTimeInterval(0.01))
            }
        }

        func test_loading_showsPlaceholder_inFixedSlot() {
            let loader = CardBrandLogoLoader(fetch: { _ in
                try await Task.sleep(nanoseconds: 5_000_000_000)
                return Data()
            })
            let row = SavedCardRow(appearance: .resolve(.default), card: card(logo: logoURL), logoLoader: loader)
            layout(row)
            XCTAssertEqual(row.logoSlotStateForTest, .placeholder)
            XCTAssertEqual(row.logoSlotFrameForTest.size, CGSize(width: 30, height: 24))
        }

        func test_loaded_showsLogo_sameSlotWidth() {
            let data = Self.pngData()
            let loader = CardBrandLogoLoader(fetch: { _ in
                try await Task.sleep(nanoseconds: 50_000_000)
                return data
            })
            let row = SavedCardRow(appearance: .resolve(.default), card: card(logo: logoURL), logoLoader: loader)
            layout(row)
            let numberXBefore = row.numberLabelFrameForTest.minX
            spin(until: { row.logoSlotStateForTest == .logo })
            layout(row)
            XCTAssertEqual(row.logoSlotStateForTest, .logo)
            XCTAssertEqual(row.logoSlotFrameForTest.size, CGSize(width: 30, height: 24))
            XCTAssertEqual(row.numberLabelFrameForTest.minX, numberXBefore, accuracy: 0.5)
        }

        func test_loadFailure_showsBadge() {
            struct Boom: Error {}
            let loader = CardBrandLogoLoader(fetch: { _ in throw Boom() })
            let row = SavedCardRow(appearance: .resolve(.default), card: card(logo: logoURL), logoLoader: loader)
            spin(until: { row.logoSlotStateForTest == .badge })
            layout(row)
            XCTAssertEqual(row.logoSlotStateForTest, .badge)
            XCTAssertEqual(row.logoSlotFrameForTest.size, CGSize(width: 30, height: 24))
        }

        func test_noLogoURL_showsBadgeImmediately() {
            let row = SavedCardRow(
                appearance: .resolve(.default), card: card(logo: nil), logoLoader: CardBrandLogoLoader())
            XCTAssertEqual(row.logoSlotStateForTest, .badge)
            let noLoader = SavedCardRow(appearance: .resolve(.default), card: card(logo: logoURL))
            XCTAssertEqual(noLoader.logoSlotStateForTest, .badge)
        }

        func test_cachedLogo_showsWithoutAnimation() {
            let data = Self.pngData()
            let loader = CardBrandLogoLoader(fetch: { _ in data })
            loader.prefetch([logoURL])
            spin(until: { loader.isCachedForTest(self.logoURL) })
            let row = SavedCardRow(appearance: .resolve(.default), card: card(logo: logoURL), logoLoader: loader)
            XCTAssertEqual(row.logoSlotStateForTest, .logo)
            XCTAssertFalse(row.didAnimateLogoForTest)
        }

        func test_expiredCard_dimsSlot() {
            let row = SavedCardRow(
                appearance: .resolve(.default), card: card(logo: nil), expiredText: "Expired")
            XCTAssertEqual(row.logoSlotAlphaForTest, 0.5, accuracy: 0.01)
        }

        func test_badge_usesBrandAbbreviation() {
            XCTAssertEqual(CardBrandBadge.text(for: "MASTERCARD"), "MC")
            XCTAssertEqual(CardBrandBadge.text(for: "Diners Club"), "DINERS")
            XCTAssertEqual(CardBrandBadge.text(for: "union_pay"), "UP")
            XCTAssertEqual(CardBrandBadge.text(for: "visa"), "VISA")
            XCTAssertEqual(CardBrandBadge.text(for: "elocard"), "ELOCA")
        }
    }

    @MainActor
    final class CardBrandLogoLoaderPrefetchTests: XCTestCase {
        func test_prefetch_thenImage_isCached() {
            let url = URL(string: "https://cdn.example.com/visa.png")!
            let data = UIGraphicsImageRenderer(size: CGSize(width: 4, height: 4)).pngData { ctx in
                UIColor.blue.setFill()
                ctx.fill(CGRect(x: 0, y: 0, width: 4, height: 4))
            }
            let loader = CardBrandLogoLoader(fetch: { _ in data })
            loader.prefetch([url, url])
            let deadline = Date().addingTimeInterval(2)
            while !loader.isCachedForTest(url), Date() < deadline {
                RunLoop.main.run(until: Date().addingTimeInterval(0.01))
            }
            var synchronous = false
            loader.image(for: url) { image in synchronous = image != nil }
            XCTAssertTrue(synchronous)
        }
    }
#endif
