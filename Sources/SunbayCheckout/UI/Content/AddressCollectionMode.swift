#if canImport(UIKit)

    /// Internal address-form mode used by the content layer (not public API).
    ///
    /// The public surface only exposes `Appearance.billingAddressEnabled` / `shippingAddressEnabled`
    /// (the host may only *disable* a form) and `…AddressStyle`. `PaymentSheet` maps the enabled flag to
    /// `.automatic` (follow the session) or `.off`; the explicit `.simple` / `.full` cases exist so the
    /// content layer can be driven directly.
    enum AddressCollectionMode: Equatable {
        /// Visible iff the session collects the address and the host has no usable entry; the form style
        /// comes from the configured `AddressFormStyle`.
        case automatic
        /// Three fields: country / line1 / postal code.
        case simple
        /// Backend-layout-driven full address form.
        case full
        /// Not shown.
        case off

        /// Maps the public "enabled" switch to a mode: enabled follows the session, disabled is off.
        static func from(enabled: Bool) -> AddressCollectionMode { enabled ? .automatic : .off }

        /// Resolves a mode against the session's collect flag and the host's address entry.
        ///
        /// - Returns: for `.automatic`, the style's mode (`.simple` / `.full`) when the session collects
        ///   the address and the host has no usable entry, else `.off`; any explicit mode unchanged.
        static func resolveAddressMode(
            _ mode: AddressCollectionMode, collect: Bool, hasUsableEntry: Bool,
            style: Appearance.AddressFormStyle = .simple
        ) -> AddressCollectionMode {
            guard mode == .automatic else { return mode }
            guard collect && !hasUsableEntry else { return .off }
            return style == .full ? .full : .simple
        }
    }
#endif
