import Foundation

/// The "unconfigured" fail-closed default services (internal, shared).
///
/// ## Why this exists
/// The public `SunbayCheckout(configuration:)` (plain init) does not accept any backend service;
/// but the UI shell and internal seams still need a pair of `PaymentService` / `CofService` to
/// assemble `CheckoutController`. The real backend adapter has not yet landed (the backend contract
/// is undefined, product-spec §7/§8), and the SDK does **not** ship its own HTTP adapter.
///
/// Therefore, when the host has not injected services via `SunbayCheckout(configuration:paymentService:cofService:)`,
/// this pair of placeholder implementations is used by default: every call **fails closed**, throwing
/// `NETWORK_UNAVAILABLE` (never silently succeeds, and never masks the unconfigured state with an empty result).
/// They exist only to make the public API shape valid and compilable, and change no external symbols.
///
/// These two types were moved out of ApplePayButton into this shared location (Task 11.5), so that
/// the "plain-init default" and the "ApplePayButton fallback" use the same fail-closed implementation.
/// They import no UIKit/PassKit, so they are also usable on a macOS host (Core constraint, AGENTS.md §2.6).

/// The unified error thrown when unconfigured (`NETWORK_UNAVAILABLE`, carrying no sensitive information).
private func unconfiguredServiceError() -> CheckoutError {
    CheckoutError(
        code: "NETWORK_UNAVAILABLE",
        message: "No backend adapter is configured for this SDK build.",
        category: .network,
        traceId: nil
    )
}

/// The "unconfigured" `PaymentService` placeholder implementation (internal, fail-closed).
struct UnconfiguredPaymentService: PaymentService {
    init() {}
    func loadSession(_ id: String) async throws -> CheckoutSession { throw unconfiguredServiceError() }
    func submit(_ req: SubmitRequest) async throws -> PaymentSnapshot { throw unconfiguredServiceError() }
    func getResult(sessionId: String) async throws -> PaymentSnapshot { throw unconfiguredServiceError() }
}

/// The "unconfigured" `CofService` placeholder implementation (internal, fail-closed).
struct UnconfiguredCofService: CofService {
    init() {}
    func listPaymentMethods(
        customerAccessSecret: String,
        sessionId: String
    ) async throws -> [SavedCard] {
        throw unconfiguredServiceError()
    }
}
