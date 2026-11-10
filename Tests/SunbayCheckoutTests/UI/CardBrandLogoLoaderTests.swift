#if canImport(UIKit)
    import UIKit
    import XCTest

    @testable import SunbayCheckout

    @MainActor
    final class CardBrandLogoLoaderTests: XCTestCase {
        private let url = URL(string: "https://cdn.example.com/visa.png")!

        private static func pngData() -> Data {
            let renderer = UIGraphicsImageRenderer(size: CGSize(width: 4, height: 4))
            return renderer.pngData { ctx in
                UIColor.red.setFill()
                ctx.fill(CGRect(x: 0, y: 0, width: 4, height: 4))
            }
        }

        private final class Counter: @unchecked Sendable {
            private let lock = NSLock()
            private var value = 0
            func increment() { lock.lock(); value += 1; lock.unlock() }
            var count: Int { lock.lock(); defer { lock.unlock() }; return value }
        }

        func test_loadsAndCachesImage() async {
            let counter = Counter()
            let data = Self.pngData()
            let loader = CardBrandLogoLoader(fetch: { _ in counter.increment(); return data })

            let first = await load(loader)
            let second = await load(loader)

            XCTAssertNotNil(first)
            XCTAssertNotNil(second)
            XCTAssertEqual(counter.count, 1)
        }

        func test_failureCompletesWithNil() async {
            struct Boom: Error {}
            let loader = CardBrandLogoLoader(fetch: { _ in throw Boom() })
            let image = await load(loader)
            XCTAssertNil(image)
        }

        func test_undecodableDataCompletesWithNil() async {
            let loader = CardBrandLogoLoader(fetch: { _ in Data("not an image".utf8) })
            let image = await load(loader)
            XCTAssertNil(image)
        }

        func test_concurrentRequestsCoalesce() async {
            let counter = Counter()
            let data = Self.pngData()
            let loader = CardBrandLogoLoader(fetch: { _ in
                counter.increment()
                try await Task.sleep(nanoseconds: 50_000_000)
                return data
            })

            async let a = load(loader)
            async let b = load(loader)
            let (imageA, imageB) = await (a, b)

            XCTAssertNotNil(imageA)
            XCTAssertNotNil(imageB)
            XCTAssertEqual(counter.count, 1)
        }

        private func load(_ loader: CardBrandLogoLoader) async -> UIImage? {
            await withCheckedContinuation { continuation in
                loader.image(for: url) { continuation.resume(returning: $0) }
            }
        }
    }
#endif
