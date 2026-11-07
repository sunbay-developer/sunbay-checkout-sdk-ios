import XCTest
@testable import Showcase

final class StringsTests: XCTestCase {
    func testEveryKeyHasNonEmptyValueInBothLanguages() {
        XCTAssertFalse(Strings.keys.isEmpty)
        for key in Strings.keys {
            for lang in ShowcaseLanguage.allCases {
                XCTAssertFalse(Strings.value(key, lang).isEmpty, "\(key) empty for \(lang)")
                XCTAssertNotEqual(Strings.value(key, lang), key, "\(key) missing for \(lang)")
            }
        }
    }

    func testLocaleCodes() {
        XCTAssertEqual(ShowcaseLanguage.en.localeCode, "en-US")
        XCTAssertEqual(ShowcaseLanguage.zh.localeCode, "zh-CN")
    }

    func testEveryCatalogNameKeyExists() {
        for product in Catalog.products {
            XCTAssertTrue(Strings.keys.contains(product.nameKey), "missing \(product.nameKey)")
        }
    }

    func testLanguageStoreDefaultsToEnglishAndSwitches() {
        let store = LanguageStore()
        XCTAssertEqual(store.language, .en)
        XCTAssertEqual(store.t("action.add"), "Add")
        store.language = .zh
        XCTAssertEqual(store.t("action.add"), Strings.value("action.add", .zh))
        XCTAssertNotEqual(store.t("action.add"), "Add")
    }

    func testMissingKeyReturnsKey() {
        XCTAssertEqual(LanguageStore().t("no.such.key"), "no.such.key")
    }
}
