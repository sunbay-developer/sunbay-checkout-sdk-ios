import Foundation

/// The public entry point of the SunbayCheckout SDK (product-spec §2.1).
///
/// The host constructs this object from a `CheckoutConfiguration`, then hands it to the UI
/// shell (`PaymentSheet` / `ApplePayButton`) to start checkout by `sessionId`.
///
/// ## Service injection (Task 11.5)
/// Real payments require a pair of backend capabilities: `PaymentService` (load session /
/// submit / query result) and `CofService` (list saved cards). The SDK does **not** ship a
/// real HTTP adapter (the backend contract is undefined, §7/§8); the host (or the example
/// app) injects its own implementations (mock or real backend adapters) via
/// `init(configuration:paymentService:cofService:)`, which is enough to run end-to-end
/// payments through the public UI.
///
/// The plain `init(configuration:)` is still retained (source compatibility): when no
/// service is injected, it falls back to the shared fail-closed `Unconfigured*` defaults —
/// any call throws `NETWORK_UNAVAILABLE` and never silently succeeds.
///
/// - Note: The version constant `sunbayCheckoutVersion` lives in a separate `Version.swift`;
///   it does not conflict with this entry **class** of the same name (different file name,
///   different symbol).
///
/// The factory that constructs a `CheckoutController` (`makeController`) is an **internal**
/// seam, used by the in-module UI shell to assemble the controller by `sessionId` and inject
/// services; it is not exposed externally.
public final class SunbayCheckout {
    /// The host-provided configuration (read-only).
    public let configuration: CheckoutConfiguration

    /// The payment backend capability injected by the host (or the fail-closed default). internal: not exposed externally, used by the UI shell / seam.
    let paymentService: any PaymentService

    /// The saved-card capability injected by the host (or the fail-closed default). internal.
    let cofService: any CofService

    /// Creates the entry point from a configuration (plain init, source compatible).
    ///
    /// With no backend service injected, `makeController` uses the shared fail-closed
    /// `Unconfigured*` defaults: any payment call throws `NETWORK_UNAVAILABLE` (never
    /// silently succeeds). To run real/mock payments end to end, use
    /// `init(configuration:paymentService:cofService:)` instead.
    ///
    /// - Parameter configuration: Host configuration.
    public convenience init(configuration: CheckoutConfiguration) {
        self.init(
            configuration: configuration,
            paymentService: UnconfiguredPaymentService(),
            cofService: UnconfiguredCofService()
        )
    }

    /// Creates the entry point from a configuration and host-provided backend services (service injection seam, Task 11.5).
    ///
    /// The host implements `PaymentService` / `CofService` (mock or real backend adapters)
    /// and injects them here; the public UI (`ApplePayButton` / the later `PaymentSheet`)
    /// drives end-to-end payments through them, with no changes needed to Core/UI.
    ///
    /// - Parameters:
    ///   - configuration: Host configuration.
    ///   - paymentService: The payment backend capability provided by the host.
    ///   - cofService: The saved-card capability provided by the host.
    public init(
        configuration: CheckoutConfiguration,
        paymentService: any PaymentService,
        cofService: any CofService
    ) {
        self.configuration = configuration
        self.paymentService = paymentService
        self.cofService = cofService
    }

    // MARK: - Internal factory seam (used by PaymentSheet / ApplePayButton)

    /// Assembles a `CheckoutController` using the (injected or default) services held by this instance (internal DI seam).
    ///
    /// This is the preferred entry point for the UI shell: the service origin is transparent
    /// to the shell — if the host injected services, those are used; otherwise the
    /// fail-closed defaults are used. This method touches no UIKit/PassKit.
    ///
    /// - Parameters:
    ///   - credentials: In-memory credential holder.
    ///   - actionHandler: `requiresAction` dispatcher.
    /// - Returns: The assembled controller.
    func makeController(
        credentials: CredentialStore,
        actionHandler: any ActionHandling
    ) -> CheckoutController {
        makeController(
            paymentService: paymentService,
            cofService: cofService,
            credentials: credentials,
            actionHandler: actionHandler
        )
    }

    /// Assembles a `CheckoutController` for the given services (internal DI seam, explicit services).
    ///
    /// Dependencies are injected via protocols, making mock/real interchangeable
    /// (product-spec global constraint).
    ///
    /// - Parameters:
    ///   - paymentService: The payment backend capability.
    ///   - cofService: The saved-card capability.
    ///   - credentials: In-memory credential holder.
    ///   - actionHandler: `requiresAction` dispatcher.
    /// - Returns: The assembled controller.
    func makeController(
        paymentService: any PaymentService,
        cofService: any CofService,
        credentials: CredentialStore,
        actionHandler: any ActionHandling
    ) -> CheckoutController {
        CheckoutController(
            paymentService: paymentService,
            cofService: cofService,
            credentials: credentials,
            actionHandler: actionHandler
        )
    }
}
