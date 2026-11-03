#if canImport(UIKit)
    import UIKit
    import XCTest

    @testable import SunbayCheckout

    /// Value-preservation test for `DynamicAddressFormView.reload(locale:)` (spec §7.3 Review-Focus).
    ///
    /// UIKit is iOS-only; on the macOS host this file is excluded by `#if canImport(UIKit)` and is
    /// vacuous. The real run requires the iOS Simulator SDK. The test enters a postal code, then
    /// calls `reload(locale:)` with a locale whose mock returns *different* labels, and asserts the
    /// entered value survives the rebuild — because values are stored as codes/raw text internally and
    /// re-applied, not read off the (recreated) UI controls.
    final class DynamicAddressFormViewTests: XCTestCase {
        func test_reloadLocalePreservesEnteredValues() {
            let service = MockAddressMetadataService()
            let v = DynamicAddressFormView(
                appearance: .resolve(.default),
                localize: { $0 },
                service: service,
                locale: "en-US"
            )
            // Drive the synchronous mock's initial build to completion.
            v.waitForLoadForTest()

            // User enters a postal code (raw text) under the en-US labels.
            v.setPostalCodeForTest("94107")
            XCTAssertEqual(v.addressInput.postalCode, "94107")
            XCTAssertEqual(v.addressInput.country, "US")

            // Switch locale; the mock returns different (zh-Hans) labels/placeholders.
            v.reload(locale: "zh-Hans")
            v.waitForLoadForTest()

            // Entered values survive the rebuild even though the labels changed.
            XCTAssertEqual(v.addressInput.postalCode, "94107")
            XCTAssertEqual(v.addressInput.country, "US")
        }
    }

    /// A synchronous in-memory `AddressMetadataService` double whose labels vary by locale, so a
    /// rebuild on `reload(locale:)` is observable while the stored codes/text must be preserved.
    private struct MockAddressMetadataService: AddressMetadataService {
        func countries(locale: String?) async throws -> AddressCountryList {
            let name = (locale == "zh-Hans") ? "美国" : "United States"
            return AddressCountryList(countries: [AddressCountry(code: "US", name: name)], detectedCountry: "US")
        }

        func countryConfig(countryCode: String, locale: String?) async throws -> AddressCountryConfig {
            let zh = (locale == "zh-Hans")
            func field(_ type: AddressFieldType, _ en: String, _ cn: String) -> AddressFieldConfig {
                AddressFieldConfig(
                    type: type,
                    required: true,
                    pattern: type == .postalCode ? "^[0-9]{5}$" : nil,
                    label: zh ? cn : en,
                    placeholder: zh ? cn : en
                )
            }
            let fields: [AddressFieldType: AddressFieldConfig] = [
                .country: field(.country, "Country", "国家"),
                .line1: field(.line1, "Address", "地址"),
                .city: field(.city, "City", "城市"),
                .state: field(.state, "State", "州"),
                .postalCode: field(.postalCode, "ZIP", "邮编"),
            ]
            let layout: [[AddressFieldType]] = [[.country], [.line1], [.city, .state, .postalCode]]
            let subs = [AddressSubdivision(code: "CA", name: zh ? "加利福尼亚" : "California")]
            return AddressCountryConfig(code: countryCode, fields: fields, layout: layout, subdivisions: subs)
        }
    }
#endif
