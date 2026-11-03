import Foundation

/// Pure-logic resolver that turns a backend `AddressCountryConfig` into ordered render rows for the
/// dynamic address form (spec §7.5).
///
/// It maps each `config.layout` row of field types to the matching `AddressFieldConfig` values from
/// `config.fields`, preserving both the row order and the left-to-right grouping within a row. Field
/// types that have no entry in `config.fields` are dropped; when names are not collected
/// (`collectName == false`), `.firstName` / `.lastName` are dropped too. Rows that become empty after
/// dropping are removed. The resolver imports no UIKit/PassKit and runs under host `swift test`, so
/// the dynamic form view controller (Task 7) can lay out rows directly from its output.
enum AddressFormLayoutResolver {
    /// Resolves the ordered render rows for an address country config.
    ///
    /// - Parameters:
    ///   - config: The backend country config (per-field config plus the visual `layout`).
    ///   - collectName: Whether first/last name fields should be included.
    /// - Returns: Ordered rows of resolved field configs; dropped field types and empty rows are
    ///   removed while the remaining order and grouping are preserved.
    static func renderRows(config: AddressCountryConfig, collectName: Bool) -> [[AddressFieldConfig]] {
        config.layout.compactMap { row -> [AddressFieldConfig]? in
            let resolved = row.compactMap { type -> AddressFieldConfig? in
                if !collectName, type == .firstName || type == .lastName {
                    return nil
                }
                return config.fields[type]
            }
            return resolved.isEmpty ? nil : resolved
        }
    }
}
