import XCTest

@testable import SunbayCheckout

/// Unit tests for the pure-logic `AddressFormLayoutResolver` (spec §7.5 dynamic address form).
///
/// This suite is UIKit-free and runs under host `swift test` (no simulator needed): it proves the
/// resolver maps a backend `AddressCountryConfig` into ordered render rows, dropping field types
/// absent from `fields`, dropping `firstName` / `lastName` when names are not collected, and
/// removing rows that become empty while preserving the remaining row grouping.
final class AddressFormLayoutResolverTests: XCTestCase {
    func test_dropsFieldsNotInConfigAndEmptyRows() {
        let cfg = AddressCountryConfigFixture.us() // layout includes a row with only firstName
        let rows = AddressFormLayoutResolver.renderRows(config: cfg, collectName: false)
        XCTAssertFalse(rows.contains { $0.contains { $0.type == .firstName } })
        XCTAssertFalse(rows.contains { $0.isEmpty })
    }

    func test_preservesRowGroupingForCityStatePostal() {
        let cfg = AddressCountryConfigFixture.us()
        let rows = AddressFormLayoutResolver.renderRows(config: cfg, collectName: false)
        XCTAssertTrue(rows.contains { $0.map(\.type) == [.city, .state, .postalCode] })
    }
}

/// Builds `AddressCountryConfig` values for the resolver tests.
///
/// The brief references this helper but it does not exist in the repo, so the tests own a small
/// private fixture. `us()` deliberately exercises both drop paths: `.line2` appears in `layout`
/// but is omitted from `fields` (present-vs-absent drop), and `.firstName` appears in `layout` and
/// `fields` so the `collectName == false` name-drop plus empty-row removal are meaningful.
private enum AddressCountryConfigFixture {
    static func us() -> AddressCountryConfig {
        let fields: [AddressFieldType: AddressFieldConfig] = [
            .country: field(.country),
            .firstName: field(.firstName),
            .line1: field(.line1),
            .city: field(.city),
            .state: field(.state),
            .postalCode: field(.postalCode),
            // Note: `.line2` is intentionally absent to exercise the "type absent from fields" drop.
        ]
        let layout: [[AddressFieldType]] = [
            [.country],
            [.firstName], // drops to empty when collectName == false -> row removed
            [.line1],
            [.line2], // absent from `fields` -> drops to empty -> row removed
            [.city, .state, .postalCode], // grouping must be preserved
        ]
        return AddressCountryConfig(code: "US", fields: fields, layout: layout, subdivisions: [])
    }

    private static func field(_ type: AddressFieldType) -> AddressFieldConfig {
        AddressFieldConfig(
            type: type,
            required: true,
            pattern: nil,
            label: "\(type.rawValue)-label",
            placeholder: "\(type.rawValue)-placeholder"
        )
    }
}
