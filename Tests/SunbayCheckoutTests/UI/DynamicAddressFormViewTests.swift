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

        /// A country change must clear the previous country's subdivision code so a stale `state`
        /// (scoped to the old country) cannot surface via `addressInput` after the rebuild.
        func test_countryChangeClearsStaleSubdivision() {
            let service = TwoCountryMockService()
            let v = DynamicAddressFormView(
                appearance: .resolve(.default),
                localize: { $0 },
                service: service,
                locale: "en-US"
            )
            v.waitForLoadForTest()

            // Country A (US) is selected by default; pick a US-specific subdivision.
            XCTAssertEqual(v.addressInput.country, "US")
            v.selectStateForTest("CA")
            XCTAssertEqual(v.addressInput.state, "CA")

            // Switch to country B (CA/Canada), whose subdivisions do not include "CA".
            v.selectCountryForTest("CA")
            v.waitForLoadForTest()

            // The stale US subdivision code must not survive the country change.
            XCTAssertEqual(v.addressInput.country, "CA")
            XCTAssertNil(v.addressInput.state)
            XCTAssertNotEqual(v.addressInput.state, "CA")
        }
    }

    /// Regression: the form must size to its rows once loaded. A leaked autoresizing-mask constraint
    /// (`height == 0`) on the hidden error container used to collapse the whole form to zero height,
    /// so the rows overlapped each other and the controls below.
    extension DynamicAddressFormViewTests {
        func test_loadedFormHasNonZeroHeightFittingAllRows() {
            let v = DynamicAddressFormView(
                appearance: .resolve(.default), localize: { $0 }, service: MockAddressMetadataService(),
                locale: "en-US")
            v.waitForLoadForTest()

            let fitting = v.systemLayoutSizeFitting(
                CGSize(width: 358, height: 0),
                withHorizontalFittingPriority: .required,
                verticalFittingPriority: .fittingSizeLevel)
            // Country + line1 + (city, state, postal) rows, each at least the 48pt field floor.
            XCTAssertGreaterThanOrEqual(fitting.height, 48 * 3)
        }
    }

    /// visibleFields filtering and postal-code validation (address form unification design).
    extension DynamicAddressFormViewTests {
        private func makeForm(
            service: any AddressMetadataService = PostalMockService(),
            options: AddressFormOptions = .billing,
            visibleFields: Set<AddressFieldType>? = nil
        ) -> DynamicAddressFormView {
            let v = DynamicAddressFormView(
                appearance: .resolve(.default), localize: { $0 }, service: service, locale: "en-US",
                options: options, visibleFields: visibleFields)
            v.waitForLoadForTest()
            return v
        }

        func test_visibleFields_filtersRows() {
            let v = makeForm(visibleFields: [.country, .line1, .postalCode])
            XCTAssertEqual(v.renderedFieldTypesForTest, [.line1, .postalCode])
            XCTAssertNil(v.addressInput.city)
        }

        func test_visibleFields_keepsNameFieldsWhenCollected() {
            let visible: Set<AddressFieldType> = [.country, .line1, .postalCode, .firstName, .lastName]
            let shipping = makeForm(options: .shipping, visibleFields: visible)
            XCTAssertTrue(shipping.renderedFieldTypesForTest.isSuperset(of: [.firstName, .lastName]))
            let billing = makeForm(options: .billing, visibleFields: visible)
            XCTAssertFalse(billing.renderedFieldTypesForTest.contains(.firstName))
            XCTAssertFalse(billing.renderedFieldTypesForTest.contains(.lastName))
        }

        func test_validate_invalidPostal_returnsFalse_andShowsInvalidMessage() {
            let v = makeForm()
            v.setPostalCodeForTest("1234")
            XCTAssertFalse(v.validate())
            XCTAssertEqual(v.postalErrorMessageForTest, "sunbay.address.postalCode.invalid")
        }

        func test_validate_emptyRequiredPostal_showsRequiredMessage() {
            let v = makeForm()
            XCTAssertFalse(v.validate())
            XCTAssertEqual(v.postalErrorMessageForTest, "sunbay.address.postalCode.required")
        }

        func test_validate_validPostal_returnsTrue_andClearsError() {
            let v = makeForm()
            v.setPostalCodeForTest("1234")
            XCTAssertFalse(v.validate())
            v.setPostalCodeForTest("94103")
            XCTAssertTrue(v.validate())
            XCTAssertNil(v.postalErrorMessageForTest)
        }

        func test_countryChange_revalidatesTypedPostal() {
            let v = makeForm()
            v.setPostalCodeForTest("94103")
            XCTAssertTrue(v.validate())
            XCTAssertNil(v.postalErrorMessageForTest)
            v.selectCountryForTest("CA")
            v.waitForLoadForTest()
            XCTAssertEqual(v.postalErrorMessageForTest, "sunbay.address.postalCode.invalid")
        }

        func test_countryWithoutPostalField_noError_andNoStalePostalInInput() {
            let v = makeForm()
            v.setPostalCodeForTest("94103")
            v.selectCountryForTest("HK")
            v.waitForLoadForTest()
            XCTAssertTrue(v.validate())
            XCTAssertNil(v.postalErrorMessageForTest)
            XCTAssertNil(v.addressInput.postalCode)
        }

        func test_validate_returnsFalse_whileLoading_withoutShowingError() {
            // No waitForLoadForTest: the metadata load has not rendered yet.
            let v = DynamicAddressFormView(
                appearance: .resolve(.default), localize: { $0 }, service: PostalMockService(),
                locale: "en-US", options: .billing, visibleFields: nil)
            XCTAssertFalse(v.validate())
            XCTAssertNil(v.postalErrorMessageForTest)
        }

        func test_validate_returnsTrue_afterLoadFailure() {
            let v = makeForm(service: FailingAddressService())
            XCTAssertTrue(v.validate())
        }
    }

    /// A postal error must not stretch the field box that sits beside the postal cell in a row.
    extension DynamicAddressFormViewTests {
        private func fieldContainers(in view: UIView) -> [FieldContainerView] {
            var result: [FieldContainerView] = []
            for sub in view.subviews {
                if let container = sub as? FieldContainerView { result.append(container) }
                result.append(contentsOf: fieldContainers(in: sub))
            }
            return result
        }

        func test_postalErrorDoesNotStretchSiblingFieldInSameRow() {
            let v = DynamicAddressFormView(
                appearance: .resolve(.default), localize: { $0 }, service: PairedPostalMockService(),
                locale: "en-US")
            let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 800))
            v.translatesAutoresizingMaskIntoConstraints = false
            window.addSubview(v)
            NSLayoutConstraint.activate([
                v.topAnchor.constraint(equalTo: window.topAnchor),
                v.leadingAnchor.constraint(equalTo: window.leadingAnchor),
                v.trailingAnchor.constraint(equalTo: window.trailingAnchor),
            ])
            v.waitForLoadForTest()
            window.layoutIfNeeded()

            // Containers in order: country, city (sibling), postal.
            let containers = fieldContainers(in: v)
            XCTAssertEqual(containers.count, 3)
            let sibling = containers[1]
            let heightBefore = sibling.frame.height
            XCTAssertGreaterThan(heightBefore, 0)

            XCTAssertFalse(v.validate())
            window.layoutIfNeeded()

            XCTAssertEqual(sibling.frame.height, heightBefore, accuracy: 0.5)
        }
    }

    /// Country on its own row, then city beside postal code.
    private struct PairedPostalMockService: AddressMetadataService {
        func countries(locale: String?) async throws -> AddressCountryList {
            AddressCountryList(countries: [AddressCountry(code: "US", name: "United States")], detectedCountry: "US")
        }

        func countryConfig(countryCode: String, locale: String?) async throws -> AddressCountryConfig {
            func field(_ type: AddressFieldType, pattern: String? = nil) -> AddressFieldConfig {
                AddressFieldConfig(
                    type: type, required: true, pattern: pattern, label: "\(type)", placeholder: "\(type)")
            }
            let fields: [AddressFieldType: AddressFieldConfig] = [
                .country: field(.country),
                .city: field(.city),
                .postalCode: field(.postalCode, pattern: "^[0-9]{5}$"),
            ]
            return AddressCountryConfig(
                code: countryCode, fields: fields, layout: [[.country], [.city, .postalCode]], subdivisions: [])
        }
    }

    private struct FailingAddressService: AddressMetadataService {
        struct Failure: Error {}
        func countries(locale: String?) async throws -> AddressCountryList { throw Failure() }
        func countryConfig(countryCode: String, locale: String?) async throws -> AddressCountryConfig {
            throw Failure()
        }
    }

    /// US (^[0-9]{5}$, required), CA (Canadian pattern, required) and HK (no postal field).
    private struct PostalMockService: AddressMetadataService {
        func countries(locale: String?) async throws -> AddressCountryList {
            AddressCountryList(
                countries: [
                    AddressCountry(code: "US", name: "United States"),
                    AddressCountry(code: "CA", name: "Canada"),
                    AddressCountry(code: "HK", name: "Hong Kong"),
                ],
                detectedCountry: "US")
        }

        func countryConfig(countryCode: String, locale: String?) async throws -> AddressCountryConfig {
            func field(_ type: AddressFieldType, pattern: String? = nil) -> AddressFieldConfig {
                AddressFieldConfig(
                    type: type, required: true, pattern: pattern, label: "\(type)", placeholder: "\(type)")
            }
            var fields: [AddressFieldType: AddressFieldConfig] = [
                .country: field(.country),
                .line1: field(.line1),
                .city: field(.city),
                .state: field(.state),
                .firstName: field(.firstName),
                .lastName: field(.lastName),
            ]
            var layout: [[AddressFieldType]] = [[.country], [.firstName, .lastName], [.line1], [.city, .state]]
            if countryCode != "HK" {
                let pattern = countryCode == "CA" ? "^[A-Z][0-9][A-Z] ?[0-9][A-Z][0-9]$" : "^[0-9]{5}$"
                fields[.postalCode] = field(.postalCode, pattern: pattern)
                layout.append([.postalCode])
            }
            return AddressCountryConfig(code: countryCode, fields: fields, layout: layout, subdivisions: [])
        }
    }

    /// A two-country mock whose countries have DISTINCT subdivisions (US: CA/NY; Canada: ON/QC), so a
    /// stale subdivision code from one country is observable if not cleared on a country change.
    private struct TwoCountryMockService: AddressMetadataService {
        func countries(locale: String?) async throws -> AddressCountryList {
            AddressCountryList(
                countries: [
                    AddressCountry(code: "US", name: "United States"),
                    AddressCountry(code: "CA", name: "Canada"),
                ],
                detectedCountry: "US"
            )
        }

        func countryConfig(countryCode: String, locale: String?) async throws -> AddressCountryConfig {
            func field(_ type: AddressFieldType, _ label: String) -> AddressFieldConfig {
                AddressFieldConfig(type: type, required: true, pattern: nil, label: label, placeholder: label)
            }
            let fields: [AddressFieldType: AddressFieldConfig] = [
                .country: field(.country, "Country"),
                .line1: field(.line1, "Address"),
                .city: field(.city, "City"),
                .state: field(.state, countryCode == "US" ? "State" : "Province"),
                .postalCode: field(.postalCode, "Postal"),
            ]
            let layout: [[AddressFieldType]] = [[.country], [.line1], [.city, .state, .postalCode]]
            let subs = (countryCode == "US")
                ? [AddressSubdivision(code: "CA", name: "California"), AddressSubdivision(code: "NY", name: "New York")]
                : [AddressSubdivision(code: "ON", name: "Ontario"), AddressSubdivision(code: "QC", name: "Quebec")]
            return AddressCountryConfig(code: countryCode, fields: fields, layout: layout, subdivisions: subs)
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
