import Foundation

/// The type of a billing/shipping address field (UI-agnostic).
///
/// Corresponds to product-spec §7.5. The raw value is the backend field-type key used in the
/// `fields` object of a country config and in the `layout` rows.
public enum AddressFieldType: String, Sendable {
    case country
    case line1
    case line2
    case city
    case state
    case postalCode
    case district
    case firstName
    case lastName
}

/// A selectable country entry for the address form country list.
///
/// Corresponds to an element of `countries` in the HPP address spec `/api/address/country` response.
public struct AddressCountry: Sendable, Equatable {
    /// ISO country code (such as `"US"`).
    public let code: String
    /// Localized display name for the current `locale`.
    public let name: String

    /// Creates a country entry.
    ///
    /// - Parameters:
    ///   - code: ISO country code.
    ///   - name: Localized display name.
    public init(code: String, name: String) {
        self.code = code
        self.name = name
    }
}

/// A subdivision (state / province / region) entry for a country.
///
/// Corresponds to an element of `subdivisions` in the §7.5 country config.
public struct AddressSubdivision: Sendable, Equatable {
    /// Subdivision code (such as `"CA"`).
    public let code: String
    /// Localized display name for the current `locale`.
    public let name: String

    /// Creates a subdivision entry.
    ///
    /// - Parameters:
    ///   - code: Subdivision code.
    ///   - name: Localized display name.
    public init(code: String, name: String) {
        self.code = code
        self.name = name
    }
}

/// The configuration for a single address field within a country config.
///
/// Corresponds to a value of the `fields` object in the §7.5 country config: whether the field is
/// required, an optional validation `pattern`, and the (already localized) `label` / `placeholder`.
public struct AddressFieldConfig: Sendable, Equatable {
    /// The field type this config describes.
    public let type: AddressFieldType
    /// Whether the field is required.
    public let required: Bool
    /// Optional regular-expression validation pattern; nil when there is no pattern.
    public let pattern: String?
    /// Localized field label.
    public let label: String
    /// Localized field placeholder.
    public let placeholder: String

    /// Creates a field config.
    ///
    /// - Parameters:
    ///   - type: The field type.
    ///   - required: Whether the field is required.
    ///   - pattern: Optional validation pattern.
    ///   - label: Localized label.
    ///   - placeholder: Localized placeholder.
    public init(type: AddressFieldType, required: Bool, pattern: String?, label: String, placeholder: String) {
        self.type = type
        self.required = required
        self.pattern = pattern
        self.label = label
        self.placeholder = placeholder
    }
}

/// The full address-form configuration for one country.
///
/// Corresponds to the HPP address spec `/api/address/country/{code}` response: the per-field config, the visual
/// `layout` (ordered rows of field types), and the `subdivisions` list. The full-mode dynamic
/// address form renders from this (labels/placeholders/names are already localized by the backend).
public struct AddressCountryConfig: Sendable, Equatable {
    /// ISO country code this config belongs to.
    public let code: String
    /// Per-field configuration keyed by field type.
    public let fields: [AddressFieldType: AddressFieldConfig]
    /// The visual layout: each inner array is a row of field types rendered left-to-right.
    public let layout: [[AddressFieldType]]
    /// The country's subdivisions (states / provinces); empty when not applicable.
    public let subdivisions: [AddressSubdivision]

    /// Creates a country config.
    ///
    /// - Parameters:
    ///   - code: ISO country code.
    ///   - fields: Per-field config keyed by field type.
    ///   - layout: Ordered rows of field types.
    ///   - subdivisions: Subdivisions list.
    public init(
        code: String,
        fields: [AddressFieldType: AddressFieldConfig],
        layout: [[AddressFieldType]],
        subdivisions: [AddressSubdivision]
    ) {
        self.code = code
        self.fields = fields
        self.layout = layout
        self.subdivisions = subdivisions
    }
}

/// The country list plus the backend-detected default country.
///
/// Corresponds to the HPP address spec `/api/address/country` response: `{ countries:[{code,name}], detectedCountry? }`.
public struct AddressCountryList: Sendable, Equatable {
    /// The selectable countries (localized names).
    public let countries: [AddressCountry]
    /// The backend-detected default country code; nil when not detected.
    public let detectedCountry: String?

    /// Creates a country list.
    ///
    /// - Parameters:
    ///   - countries: Selectable countries.
    ///   - detectedCountry: Detected default country code, defaults to nil.
    public init(countries: [AddressCountry], detectedCountry: String? = nil) {
        self.countries = countries
        self.detectedCountry = detectedCountry
    }
}

/// The user-entered address values (UI-agnostic; carries no sensitive payment data, see §7.1).
///
/// Both the simple and full address forms produce this type. Values are stored as codes where
/// applicable (`country`, `state` subdivision code) so they survive a locale change (names are
/// display-only). Simple mode fills only `country` / `line1` / `postalCode`.
public struct AddressInput: Sendable, Equatable {
    /// ISO country code.
    public var country: String?
    /// Address line 1.
    public var line1: String?
    /// Address line 2.
    public var line2: String?
    /// City.
    public var city: String?
    /// State / subdivision code.
    public var state: String?
    /// Postal code.
    public var postalCode: String?
    /// District.
    public var district: String?
    /// First name.
    public var firstName: String?
    /// Last name.
    public var lastName: String?
    /// Phone number.
    public var phone: String?
    /// Email address.
    public var email: String?

    /// Creates an address input; all fields default to nil.
    ///
    /// - Parameters:
    ///   - country: ISO country code.
    ///   - line1: Address line 1.
    ///   - line2: Address line 2.
    ///   - city: City.
    ///   - state: State / subdivision code.
    ///   - postalCode: Postal code.
    ///   - district: District.
    ///   - firstName: First name.
    ///   - lastName: Last name.
    ///   - phone: Phone number.
    ///   - email: Email address.
    public init(
        country: String? = nil,
        line1: String? = nil,
        line2: String? = nil,
        city: String? = nil,
        state: String? = nil,
        postalCode: String? = nil,
        district: String? = nil,
        firstName: String? = nil,
        lastName: String? = nil,
        phone: String? = nil,
        email: String? = nil
    ) {
        self.country = country
        self.line1 = line1
        self.line2 = line2
        self.city = city
        self.state = state
        self.postalCode = postalCode
        self.district = district
        self.firstName = firstName
        self.lastName = lastName
        self.phone = phone
        self.email = email
    }
}
