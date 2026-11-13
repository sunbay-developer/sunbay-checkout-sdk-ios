import Foundation

#if canImport(UIKit)
    import UIKit
#endif

/// The public entry point of the SunbayCheckout SDK (product-spec §2.1).
///
/// The host constructs this object from a `CheckoutConfiguration`, then hands it to the UI
/// shell (`PaymentSheet` / `CheckoutElements`) to start checkout by `sessionId`.
///
/// ## Backends
/// `init(configuration:)` talks to the real Sunbay backend for the configured environment
/// (saved cards degrade to none in this phase; address metadata loads from the same host). A host or
/// the example app may instead inject its own `PaymentService` / `CofService` (mock or custom adapters) via
/// `init(configuration:paymentService:cofService:)`.
///
/// - Note: The version constant `sunbayCheckoutVersion` lives in a separate `Version.swift`;
///   it does not conflict with this entry **class** of the same name (different file name,
///   different symbol).
///
/// ## Unresolved-payment recovery
/// The SDK does not client-poll or hold a cross-attempt marker: a `.pending` / `.unknown` outcome is
/// reported as-is and the host recovers the final state out of band via `retrievePayment` / webhook
/// (spec §4.3). Nothing about an unresolved outcome is persisted across a process restart.
///
/// The factory that constructs a `CheckoutController` (`makeController`) is an **internal**
/// seam, used by the in-module UI shell to assemble the controller by `sessionId` and inject
/// services; it is not exposed externally.
public final class SunbayCheckout {
    /// The host-provided configuration (read-only).
    public let configuration: CheckoutConfiguration

    /// Builds the (payment, saved-card) service pair for one controller (internal).
    ///
    /// The factory receives the controller's own `CredentialStore` so a default `HTTPPaymentService`
    /// shares the credentials held by that sheet. The injecting initializer wraps its fixed services.
    let serviceFactory: (CredentialStore) -> (any PaymentService, any CofService)

    /// The address-metadata capability used by the full-mode address form (or the fail-soft default).
    ///
    /// Always stored wrapped in an `AddressMetadataCache` (caching + in-flight dedup, §7.3). The UI
    /// shell (`PaymentSheet`) reads this to build the content VC's `addressService`. internal: not
    /// exposed externally. UI-agnostic (Core type; never imports UIKit).
    let addressMetadataService: any AddressMetadataService

    /// Screen metrics snapshot for `userDeviceInfo`; recorded on the main actor when the UI shell
    /// presents (`PaymentSheet.present`) and read from the submit path (which runs off the main thread).
    let screenMetrics: ScreenMetricsStore

    /// Diagnostics channel shared by this instance's controllers and views (internal).
    let diagnostics: DiagnosticsReporter

    /// Receives non-fatal diagnostics (warnings and non-terminal errors), always on the main thread.
    ///
    /// Events raised before a handler is set are buffered (last 50) and replayed in order when it is
    /// assigned. Diagnostics never contain card values or secrets.
    public var onDiagnostic: ((CheckoutDiagnostic) -> Void)? {
        get { diagnostics.handler }
        set { diagnostics.handler = newValue }
    }

    /// Creates the entry point from a configuration; talks to the real Sunbay backend for the
    /// configured environment (the default).
    ///
    /// Saved cards are listed through the real `card/list` endpoint when the session allows COF and
    /// a customer access secret is held; any listing failure degrades to no saved cards.
    /// To run mock payments, use `init(configuration:paymentService:cofService:)`.
    ///
    /// - Parameter configuration: Host configuration.
    public convenience init(configuration: CheckoutConfiguration) {
        self.init(configuration: configuration, urlSession: nil)
    }

    /// Internal seam: the default real-backend wiring with an optional injected `URLSession` (tests).
    convenience init(configuration: CheckoutConfiguration, urlSession: URLSession?) {
        let client = urlSession.map {
            SunbayAPIClient(environment: configuration.environment, locale: configuration.locale, session: $0)
        } ?? SunbayAPIClient(environment: configuration.environment, locale: configuration.locale)
        let metrics = ScreenMetricsStore()
        let diagnostics = DiagnosticsReporter()
        self.init(
            configuration: configuration,
            serviceFactory: { credentials in
                (
                    HTTPPaymentService(
                        client: client,
                        credentials: credentials,
                        deviceInfo: { DeviceInfoCollector.collect(screen: metrics.current) }),
                    HTTPCofService(client: client)
                )
            },
            addressMetadataService: ReportingAddressMetadataService(
                wrapping: HTTPAddressMetadataService(client: client), reporter: diagnostics),
            screenMetrics: metrics,
            diagnostics: diagnostics)
    }

    /// Internal designated seam: any per-controller service factory.
    init(
        configuration: CheckoutConfiguration,
        serviceFactory: @escaping (CredentialStore) -> (any PaymentService, any CofService),
        addressMetadataService: (any AddressMetadataService)? = nil,
        screenMetrics: ScreenMetricsStore = ScreenMetricsStore(),
        diagnostics: DiagnosticsReporter = DiagnosticsReporter()
    ) {
        self.configuration = configuration
        self.diagnostics = diagnostics
        self.serviceFactory = serviceFactory
        self.screenMetrics = screenMetrics
        self.addressMetadataService = AddressMetadataCache(
            wrapping: addressMetadataService ?? EmptyAddressMetadataService())
    }

    /// Creates the entry point from a configuration and host-provided backend services (service injection seam, Task 11.5).
    ///
    /// The host implements `PaymentService` / `CofService` (mock or real backend adapters)
    /// and injects them here; the public UI (`CheckoutElements` / `PaymentSheet`) drives
    /// end-to-end payments through them, with no changes needed to Core/UI.
    ///
    /// The optional `addressMetadataService` powers the full-mode address form (§7.5). It defaults
    /// to a fail-soft empty service (returns an empty country list / minimal config rather than
    /// throwing), so hosts that never opt into `.full` address collection do not have to inject
    /// anything (`.simple`, the default, falls back to a local config when metadata is empty). Whatever is supplied is
    /// wrapped in an `AddressMetadataCache` (caching + in-flight dedup).
    ///
    /// - Parameters:
    ///   - configuration: Host configuration.
    ///   - paymentService: The payment backend capability provided by the host.
    ///   - cofService: The saved-card capability provided by the host.
    ///   - addressMetadataService: The address-metadata capability (full-mode address form); `nil` (the default) uses a fail-soft empty service.
    public convenience init(
        configuration: CheckoutConfiguration,
        paymentService: any PaymentService,
        cofService: any CofService,
        addressMetadataService: (any AddressMetadataService)? = nil
    ) {
        self.init(
            configuration: configuration,
            serviceFactory: { _ in (paymentService, cofService) },
            addressMetadataService: addressMetadataService)
    }

    // MARK: - Internal factory seam (used by PaymentSheet / CheckoutElements)

    /// Assembles a `CheckoutController` using the (injected or default) services held by this instance (internal DI seam).
    ///
    /// This is the preferred entry point for the UI shell: the service origin is transparent
    /// to the shell — if the host injected services, those are used; otherwise the default
    /// real-backend services (built around the given `credentials`) are used. This method touches no UIKit/PassKit.
    ///
    /// - Parameters:
    ///   - credentials: In-memory credential holder.
    ///   - actionHandler: `requiresAction` dispatcher.
    /// - Returns: The assembled controller.
    func makeController(
        credentials: CredentialStore,
        actionHandler: any ActionHandling
    ) -> CheckoutController {
        let (paymentService, cofService) = serviceFactory(credentials)
        return makeController(
            paymentService: paymentService,
            cofService: cofService,
            credentials: credentials,
            actionHandler: actionHandler,
            cardOnFile: configuration.cardOnFile
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
    ///   - cardOnFile: Host card-on-file options.
    /// - Returns: The assembled controller.
    func makeController(
        paymentService: any PaymentService,
        cofService: any CofService,
        credentials: CredentialStore,
        actionHandler: any ActionHandling,
        cardOnFile: CardOnFileOptions = CardOnFileOptions()
    ) -> CheckoutController {
        CheckoutController(
            paymentService: paymentService,
            cofService: cofService,
            credentials: credentials,
            actionHandler: actionHandler,
            cardOnFile: cardOnFile,
            reporter: diagnostics
        )
    }
}

#if canImport(UIKit)
    /// The UI-shell dependencies assembled once from a `SunbayCheckout` (internal): shared by
    /// `PaymentSheet` and `CheckoutElements` so both wire the controller, wallet and localization identically.
    struct UIWiring {
        let controller: CheckoutController
        let localize: (String) -> String
        let localeCode: String?
        let appearance: Appearance
        let paymentSheetTitle: String?
        let addressMetadataService: any AddressMetadataService
        let walletAuthorizer: any WalletAuthorizing
        let walletMerchantId: String?
        let screenMetrics: ScreenMetricsStore
        let paymentMethodFilter: PaymentMethodFilter
        let diagnostics: DiagnosticsReporter
    }

    extension SunbayCheckout {
        /// Builds the controller (fresh `CredentialStore`, real `ActionHandler`/`WebAuthOpener`), the real PassKit
        /// wallet and the localization / merchant-id inputs from this instance's configuration.
        func makeUIWiring() -> UIWiring {
            UIWiring(
                controller: makeController(
                    credentials: CredentialStore(),
                    actionHandler: ActionHandler(webAuthOpener: WebAuthOpener())),
                localize: LocalizationResolver(explicitLocale: configuration.locale).localizedNoComment,
                localeCode: configuration.locale,
                appearance: configuration.appearance ?? .default,
                paymentSheetTitle: configuration.paymentSheetTitle,
                addressMetadataService: addressMetadataService,
                walletAuthorizer: WalletAuthorizer(),
                walletMerchantId: resolveMerchantId(
                    configured: configuration.applePayMerchantId, sessionProvided: nil),
                screenMetrics: screenMetrics,
                paymentMethodFilter: configuration.paymentMethodFilter,
                diagnostics: diagnostics)
        }
    }

    extension DriverOptions {
        /// The driver options for a UI shell: which address forms it will show is derived from `appearance`
        /// (it needs UIKit-gated types), so the Core driver only receives the result.
        static func forUI(appearance: Appearance, failsWhenNoMethodAvailable: Bool) -> DriverOptions {
            let billingEnabled = appearance.billingAddressEnabled
            let shippingEnabled = appearance.shippingAddressEnabled
            let billingStyle = appearance.billingAddressStyle
            let shippingStyle = appearance.shippingAddressStyle
            return DriverOptions(
                expressOff: appearance.expressPosition == .off,
                failsWhenNoMethodAvailable: failsWhenNoMethodAvailable,
                addressFormsShown: { session, billingUsable, shippingUsable in
                    (
                        AddressCollectionMode.resolveAddressMode(
                            .from(enabled: billingEnabled), collect: session.collectBillingAddress,
                            hasUsableEntry: billingUsable, style: billingStyle) != .off,
                        AddressCollectionMode.resolveAddressMode(
                            .from(enabled: shippingEnabled), collect: session.collectShippingAddress,
                            hasUsableEntry: shippingUsable, style: shippingStyle) != .off
                    )
                })
        }
    }
#endif
