import Foundation

/// L2, planned v2 — not part of the public API.
///
/// A reserved placeholder for the embedded payment element (product-spec §2.6). L2
/// "embedded checkout element" is planned for the v2 release, at which point it will embed
/// inline UI into the host's own page (as opposed to L1 `PaymentSheet`'s black-box
/// full-screen/modal page).
///
/// This task (Task 12) only **reserves the name and the directory**:
/// - Deliberately kept **internal** (not `public`) — it is not part of the current public
///   API and is not exposed to the host; the public API audit (Final verification) uses this
///   to check it is not mistakenly marked `public`.
/// - It contains no behavior/UI dependency, so it needs no UIKit and can be pure Swift; the
///   `#if canImport(UIKit)` gate will be introduced when v2 is actually implemented.
///
/// - Warning: Do not add public members to this type or mark it `public`; it is a reserved
///   placeholder, and the real implementation is part of the later v2 plan.
struct EmbeddedPaymentElement {
    /// Reserved parameterless initializer (placeholder). The v2 implementation will replace it with dependencies such as `SunbayCheckout` + `sessionId`.
    init() {}
}
