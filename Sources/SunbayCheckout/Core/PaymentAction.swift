import Foundation

/// The further action issued by the backend in the `requiresAction` (R) state.
///
/// Derived from the `action.type` field of the backend result JSON (see product-spec §7.4 / §4.5).
/// The first version only implements `redirect`; `qrCode` / `showContent` are reserved in the
/// protocol (handled as UNSUPPORTED_CAPABILITY at runtime, see Task 8); unrecognized types are
/// downgraded to `.unknown` so decoding never crashes.
enum PaymentAction: Sendable, Equatable {
    /// Redirect to a third-party payment web page (`action.redirectUrl`).
    case redirect(url: URL)
    /// Display a QR code (not implemented in the first version).
    case qrCode
    /// Display content (not implemented in the first version).
    case showContent
    /// Unknown / unsupported action type.
    case unknown
}
