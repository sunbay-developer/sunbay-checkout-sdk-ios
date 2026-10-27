import XCTest
@testable import SunbayCheckout

final class LocalizationResolverTests: XCTestCase {
    func test_explicitZhCN_resolvesToZhHansBundle() {
        let r = LocalizationResolver(explicitLocale: "zh-CN", systemLanguages: ["en-US"])
        XCTAssertEqual(r.localized("sunbay.sheet.pay", "c"), "支付")
    }

    func test_explicitEnUS_resolvesToEnglish() {
        let r = LocalizationResolver(explicitLocale: "en-US", systemLanguages: ["zh-Hans"])
        XCTAssertEqual(r.localized("sunbay.sheet.pay", "c"), "Pay")
    }

    func test_nilExplicit_fallsBackToSystemThenEnglish() {
        let r = LocalizationResolver(explicitLocale: nil, systemLanguages: ["zh-CN"])
        XCTAssertEqual(r.localized("sunbay.sheet.pay", "c"), "支付")
        let r2 = LocalizationResolver(explicitLocale: nil, systemLanguages: ["fr-FR"])
        XCTAssertEqual(r2.localized("sunbay.sheet.pay", "c"), "Pay")
    }

    func test_unknownCode_fallsBackToEnglish() {
        let r = LocalizationResolver(explicitLocale: "xx", systemLanguages: [])
        XCTAssertEqual(r.localized("sunbay.sheet.pay", "c"), "Pay")
    }
}
