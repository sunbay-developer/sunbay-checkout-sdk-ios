import XCTest

@testable import SunbayCheckout

@MainActor
final class CardSchemeResolverTests: XCTestCase {
    /// A BIN service that answers only after a delay, so a lookup is in flight when the field is cleared.
    private struct SlowBinService: CardBinService {
        func recognize(bin: String, sessionId: String) async throws -> String? {
            try await Task.sleep(nanoseconds: 300_000_000)
            return "visa"
        }
    }

    /// Clearing the number (`digitsChanged("")`, what `CardFormView.clear()` sends) must cancel the
    /// in-flight lookup so a late answer can never re-apply a scheme to the emptied form.
    func test_digitsChangedEmpty_cancelsInFlightLookup() async throws {
        var applied: [String?] = []
        let resolver = CardSchemeResolver(
            service: SlowBinService(), sessionId: "s", debounce: 0, onChange: { applied.append($0) })
        resolver.digitsChanged("424242")
        try await Task.sleep(nanoseconds: 50_000_000)
        resolver.digitsChanged("")
        try await Task.sleep(nanoseconds: 500_000_000)
        XCTAssertTrue(applied.isEmpty, "a cleared field must not receive a late scheme: \(applied)")
        XCTAssertNil(resolver.scheme)
    }
}
