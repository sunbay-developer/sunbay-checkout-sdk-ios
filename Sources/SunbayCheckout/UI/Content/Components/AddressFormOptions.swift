#if canImport(UIKit)
    /// Per-form switches for the address form components (internal; not exposed to integrators yet).
    ///
    /// Like HPP's `AddressForm collectName`, billing starts without names and shipping with them.
    /// Shipping additionally collects a phone number; billing does not.
    struct AddressFormOptions: Equatable {
        /// Whether first / last name fields are collected.
        var collectName: Bool
        /// Whether a phone number field is collected.
        var collectPhone: Bool

        /// Billing address form: no names, no phone.
        static let billing = AddressFormOptions(collectName: false, collectPhone: false)
        /// Shipping address form: names and phone are collected.
        static let shipping = AddressFormOptions(collectName: true, collectPhone: true)
    }
#endif
