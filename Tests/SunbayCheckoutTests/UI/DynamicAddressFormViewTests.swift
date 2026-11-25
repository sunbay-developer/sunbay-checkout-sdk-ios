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

        /// `clearValues()` must reset every visible address control: the state-menu label and the
        /// model email too, not just the text fields.
        func test_clearValues_resetsStateMenuLabelAndEmail() {
            let v = DynamicAddressFormView(
                appearance: .resolve(.default), localize: { $0 }, service: TwoCountryMockService(),
                locale: "en-US")
            v.waitForLoadForTest()
            v.selectStateForTest("CA")
            v.setEmailForTest("a@b.co")
            XCTAssertNotNil(v.stateTitleForTest)
            XCTAssertEqual(v.addressInput.email, "a@b.co")

            v.clearValues()

            XCTAssertNil(v.stateTitleForTest, "the state menu label must be reset")
            XCTAssertNil(v.addressInput.state)
            XCTAssertNil(v.addressInput.email)
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

        /// Fills the PostalMockService's required non-postal text fields (line1 / city / state).
        private func fillRequired(_ v: DynamicAddressFormView) {
            v.setTextForTest(.line1, "1 Main St")
            v.setTextForTest(.city, "San Francisco")
            v.setTextForTest(.state, "CA")
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
            fillRequired(v)
            v.setPostalCodeForTest("1234")
            XCTAssertFalse(v.validate())
            v.setPostalCodeForTest("94103")
            XCTAssertTrue(v.validate())
            XCTAssertNil(v.postalErrorMessageForTest)
        }

        func test_countryChange_revalidatesTypedPostal() {
            let v = makeForm()
            fillRequired(v)
            v.setPostalCodeForTest("94103")
            XCTAssertTrue(v.validate())
            XCTAssertNil(v.postalErrorMessageForTest)
            v.selectCountryForTest("CA")
            v.waitForLoadForTest()
            XCTAssertEqual(v.postalErrorMessageForTest, "sunbay.address.postalCode.invalid")
        }

        func test_countryWithoutPostalField_noError_andNoStalePostalInInput() {
            let v = makeForm()
            fillRequired(v)
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

        func test_validate_emptyRequiredFields_showRequiredMessages() {
            let v = DynamicAddressFormView(
                appearance: .resolve(.default),
                localize: { $0 == "sunbay.address.error.requiredFormat" ? "%@ is required." : $0 },
                service: PostalMockService(), locale: "en-US")
            v.waitForLoadForTest()
            v.setPostalCodeForTest("94103")
            XCTAssertFalse(v.validate())
            XCTAssertEqual(v.errorMessageForTest(.line1), "line1 is required.")
            XCTAssertEqual(v.errorMessageForTest(.city), "city is required.")
            XCTAssertNil(v.postalErrorMessageForTest)
        }

        func test_simpleMode_emptyLine1_blocks_thenFilledPasses() {
            let v = makeForm(visibleFields: [.country, .line1, .postalCode])
            v.setPostalCodeForTest("94103")
            XCTAssertFalse(v.validate())
            XCTAssertNotNil(v.errorMessageForTest(.line1))
            // Fields hidden in simple mode (city / state) are never validated.
            XCTAssertNil(v.errorMessageForTest(.city))
            v.setTextForTest(.line1, "1 Main St")
            XCTAssertTrue(v.validate())
            XCTAssertNil(v.errorMessageForTest(.line1))
        }

        func test_optionalField_emptyPasses() {
            let v = makeForm(service: OptionalLine2Service())
            v.setTextForTest(.line1, "1 Main St")
            XCTAssertTrue(v.validate())
        }

        func test_fieldTitleUsesLabel() {
            let v = makeForm(service: OptionalLine2Service())
            XCTAssertEqual(v.titleForTest(.line1), "Address Line 1")
            XCTAssertEqual(v.titleForTest(.line2), "Address Line 2")
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
    /// A US-like config: required line1 (label differs from placeholder), optional line2, no postal field.
    private struct OptionalLine2Service: AddressMetadataService {
        func countries(locale: String?) async throws -> AddressCountryList {
            AddressCountryList(countries: [AddressCountry(code: "US", name: "United States")], detectedCountry: "US")
        }

        func countryConfig(countryCode: String, locale: String?) async throws -> AddressCountryConfig {
            AddressCountryConfig(
                code: countryCode,
                fields: [
                    .line1: AddressFieldConfig(
                        type: .line1, required: true, pattern: nil, label: "Address Line 1",
                        placeholder: "Street, P.O. box, company"),
                    .line2: AddressFieldConfig(
                        type: .line2, required: false, pattern: nil, label: "Address Line 2",
                        placeholder: "Apt, suite, unit, floor"),
                ],
                layout: [[.country], [.line1], [.line2]], subdivisions: [])
        }
    }

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

    /// Loading states: skeleton on the initial load, and below the country row on a slow country change.
    extension DynamicAddressFormViewTests {
        private func spin(_ seconds: TimeInterval) {
            RunLoop.main.run(until: Date().addingTimeInterval(seconds))
        }

        func test_initialLoad_showsSkeleton() {
            let v = DynamicAddressFormView(
                appearance: .resolve(.default), localize: { $0 },
                service: DelayedAddressService(delays: ["US": 0.5]), locale: "en-US")
            XCTAssertTrue(v.isSkeletonVisibleForTest)
            v.waitForLoadForTest()
            XCTAssertFalse(v.isSkeletonVisibleForTest)
        }

        func test_countryChange_slowLoad_keepsCountryRowAndShowsSkeleton() {
            let v = DynamicAddressFormView(
                appearance: .resolve(.default), localize: { $0 },
                service: DelayedAddressService(delays: ["CA": 0.5]), locale: "en-US", skeletonDelay: 0)
            v.waitForLoadForTest()
            v.selectCountryForTest("CA")
            spin(0.1)
            XCTAssertTrue(v.isSkeletonVisibleForTest)
            XCTAssertTrue(v.isCountryRowVisibleForTest)
            v.waitForLoadForTest()
            XCTAssertFalse(v.isSkeletonVisibleForTest)
            XCTAssertTrue(v.isCountryRowVisibleForTest)
            XCTAssertEqual(v.addressInput.country, "CA")
        }

        func test_countryChange_fastLoad_neverShowsSkeleton() {
            let v = DynamicAddressFormView(
                appearance: .resolve(.default), localize: { $0 },
                service: DelayedAddressService(delays: [:]), locale: "en-US", skeletonDelay: 10)
            v.waitForLoadForTest()
            v.selectCountryForTest("CA")
            v.waitForLoadForTest()
            XCTAssertFalse(v.didShowCountrySkeletonForTest)
            XCTAssertTrue(v.renderedFieldTypesForTest.contains(.postalCode))
        }

        func test_countryChange_preservesTypedValues() {
            let v = DynamicAddressFormView(
                appearance: .resolve(.default), localize: { $0 },
                service: DelayedAddressService(delays: ["CA": 0.3]), locale: "en-US", skeletonDelay: 0)
            v.waitForLoadForTest()
            v.setTextForTest(.line1, "1 Main St")
            v.setTextForTest(.city, "Toronto")
            v.selectCountryForTest("CA")
            spin(0.1)
            XCTAssertTrue(v.isSkeletonVisibleForTest)
            v.waitForLoadForTest()
            XCTAssertEqual(v.addressInput.line1, "1 Main St")
            XCTAssertEqual(v.addressInput.city, "Toronto")
        }

        func test_staleCountryResponse_isIgnored() {
            let v = DynamicAddressFormView(
                appearance: .resolve(.default), localize: { $0 },
                service: DelayedAddressService(delays: ["CA": 0.4]), locale: "en-US", skeletonDelay: 0)
            v.waitForLoadForTest()
            v.selectCountryForTest("CA")
            v.selectCountryForTest("HK")
            v.waitForLoadForTest()
            // HK has no postal field; CA's late response must not rebuild the form with one.
            spin(0.6)
            XCTAssertEqual(v.addressInput.country, "HK")
            XCTAssertFalse(v.renderedFieldTypesForTest.contains(.postalCode))
            XCTAssertFalse(v.isSkeletonVisibleForTest)
        }

        func test_countryChangeFailure_showsError() {
            let v = DynamicAddressFormView(
                appearance: .resolve(.default), localize: { $0 },
                service: DelayedAddressService(delays: [:], failing: ["CA"]), locale: "en-US", skeletonDelay: 0)
            v.waitForLoadForTest()
            v.selectCountryForTest("CA")
            v.waitForLoadForTest()
            XCTAssertFalse(v.isSkeletonVisibleForTest)
            XCTAssertTrue(v.isErrorVisibleForTest)
        }

        func test_validate_returnsFalseDuringCountryReload() {
            let v = DynamicAddressFormView(
                appearance: .resolve(.default), localize: { $0 },
                service: DelayedAddressService(delays: ["CA": 0.5]), locale: "en-US", skeletonDelay: 0)
            v.waitForLoadForTest()
            v.selectCountryForTest("CA")
            XCTAssertFalse(v.validate())
            v.waitForLoadForTest()
        }
    }

    /// Wraps `PostalMockService` with a per-country config delay and optional per-country failure.
    private struct DelayedAddressService: AddressMetadataService {
        struct Failure: Error {}
        let delays: [String: TimeInterval]
        var failing: Set<String> = []

        func countries(locale: String?) async throws -> AddressCountryList {
            try await PostalMockService().countries(locale: locale)
        }

        func countryConfig(countryCode: String, locale: String?) async throws -> AddressCountryConfig {
            if let delay = delays[countryCode] {
                try await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            }
            if failing.contains(countryCode) { throw Failure() }
            return try await PostalMockService().countryConfig(countryCode: countryCode, locale: locale)
        }
    }

    /// Regression: the hidden loading skeleton must not constrain the loaded form's height. A form with more
    /// rows than the skeleton used to be squeezed to the skeleton's height, compressing the fields.
    extension DynamicAddressFormViewTests {
        private func fieldBoxes(in root: UIView) -> [FieldContainerView] {
            var found: [FieldContainerView] = []
            func walk(_ view: UIView) {
                if let box = view as? FieldContainerView, !box.isHidden { found.append(box) }
                view.subviews.forEach(walk)
            }
            walk(root)
            return found
        }

        @discardableResult
        private func layOut(_ v: DynamicAddressFormView) -> UIView {
            // A real window, as in the app: constraint updates for rebuilt rows run in its layout pass.
            let host = UIWindow(frame: CGRect(x: 0, y: 0, width: 358, height: 2000))
            host.isHidden = false
            v.translatesAutoresizingMaskIntoConstraints = false
            host.addSubview(v)
            NSLayoutConstraint.activate([
                v.topAnchor.constraint(equalTo: host.topAnchor),
                v.leadingAnchor.constraint(equalTo: host.leadingAnchor),
                v.trailingAnchor.constraint(equalTo: host.trailingAnchor),
            ])
            host.layoutIfNeeded()
            return host
        }

        private func assertFieldsNotCompressed(_ v: DynamicAddressFormView, file: StaticString = #filePath, line: UInt = #line) {
            let boxes = fieldBoxes(in: v)
            XCTAssertGreaterThan(boxes.count, 4, file: file, line: line)
            for box in boxes {
                XCTAssertGreaterThanOrEqual(
                    box.frame.height, FloatingLabelMetrics.minFieldHeight - 0.5,
                    "field box compressed to \(box.frame.height)", file: file, line: line)
            }
        }

        func test_loadedFormTallerThanSkeleton_fieldsAreNotCompressed() {
            let v = DynamicAddressFormView(
                appearance: .resolve(.default), localize: { $0 }, service: PostalMockService(),
                locale: "en-US", options: .shipping)
            v.waitForLoadForTest()
            layOut(v)
            assertFieldsNotCompressed(v)
        }

        func test_countryChange_toTallerForm_fieldsAreNotCompressed() {
            let v = DynamicAddressFormView(
                appearance: .resolve(.default), localize: { $0 },
                service: DelayedAddressService(delays: ["CA": 0.3]), locale: "en-US", options: .shipping,
                skeletonDelay: 0)
            v.waitForLoadForTest()
            let host = layOut(v)
            v.selectCountryForTest("CA")
            v.waitForLoadForTest()
            host.layoutIfNeeded()
            assertFieldsNotCompressed(v)
        }
    }
#endif
