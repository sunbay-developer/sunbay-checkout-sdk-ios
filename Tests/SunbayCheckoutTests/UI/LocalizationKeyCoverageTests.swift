import XCTest
@testable import SunbayCheckout

/// Verifies that every canonical UI string key resolves to a real value in
/// both the `en` and `zh-Hans` tables. A key that is missing from a table
/// resolves to the key itself (the sentinel-default pattern), so asserting
/// `resolved != key` catches any gap in either language.
///
/// This test is not UIKit-dependent and runs under host `swift test`.
final class LocalizationKeyCoverageTests: XCTestCase {
    private func resolve(_ key: String, _ locale: String) -> String {
        LocalizationResolver(explicitLocale: locale, systemLanguages: [])
            .localizedNoComment(key)
    }

    func test_allNewKeysPresentInEnAndZhHans() {
        for key in SunbayUIStringKeys.all {
            XCTAssertNotEqual(resolve(key, "en"), key, "missing en: \(key)")
            XCTAssertNotEqual(resolve(key, "zh-Hans"), key, "missing zh-Hans: \(key)")
        }
    }
}
