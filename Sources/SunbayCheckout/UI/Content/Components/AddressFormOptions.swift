#if canImport(UIKit)
    /// Per-form switches for the address form components (internal; not exposed to integrators yet).
    ///
    /// Like HPP's `AddressForm collectName`, billing starts without names and shipping with them.
    /// Future per-form switches (for example phone) are added here.
    struct AddressFormOptions: Equatable {
        /// Whether first / last name fields are collected.
        var collectName: Bool

        /// Billing address form: names are not collected.
        static let billing = AddressFormOptions(collectName: false)
        /// Shipping address form: names are collected.
        static let shipping = AddressFormOptions(collectName: true)
    }
#endif
