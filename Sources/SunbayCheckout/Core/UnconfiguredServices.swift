import Foundation

/// The "unconfigured" fail-closed default for saved cards (internal, shared).
///
/// The real HTTP `CofService` adapter has not landed yet (saved cards are out of scope for the
/// first real-backend phase), so the default `SunbayCheckout(configuration:)` and the
/// `ApplePayButton` fallback use this implementation: every call **fails closed**, throwing
/// `NETWORK_UNAVAILABLE`; callers degrade to "no saved cards". It imports no UIKit/PassKit.

/// The unified error thrown when unconfigured (`NETWORK_UNAVAILABLE`, carrying no sensitive information).
private func unconfiguredServiceError() -> CheckoutError {
    CheckoutError(
        code: "NETWORK_UNAVAILABLE",
        message: "No backend adapter is configured for this SDK build.",
        category: .network,
        traceId: nil
    )
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
