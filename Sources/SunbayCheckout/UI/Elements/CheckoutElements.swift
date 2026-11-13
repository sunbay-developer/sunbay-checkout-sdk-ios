#if canImport(UIKit)
    import UIKit

    /// The shared group behind the embeddable payment components (`ExpressCheckoutElement`, `CardElement`).
    ///
    /// `create` loads the session once; every component made from the group shares one payment lock, one
    /// expiry timer and one outcome history (see `ElementsCoordinator`). The merchant arranges the
    /// components in its own screen and owns any Pay button.
    ///
    /// ## Errors
    /// `create` throws a `CheckoutError` only when the session itself cannot be loaded (or is expired).
    /// "No method available", "Apple Pay unavailable" or "everything hidden" never throw: the components
    /// report `isAvailable == false` and render zero-height views.
    ///
    /// ## Security
    /// Nothing sensitive crosses this API: no card values, wallet tokens, secrets or ciphertext. `close()`
    /// and deinit end the session (clearing the credential held in memory). If only a `CardElement` is
    /// retained and the group is released, the group's deinit closes the session but that element is not
    /// locked (no pay path exists); keep the group alive while its components are on screen.
    @MainActor
    public final class CheckoutElements {
        /// Per-session inputs, like `PaymentSheet`'s initializer.
        public struct Configuration {
            /// COF credential from the host backend (memory only, never logged).
            public var customerAccessSecret: String?
            /// Client secret issued by the host backend with the session (memory only, never logged).
            public var checkoutClientSecret: String?
            /// A billing address the host already knows; sent as is and wins over what the user enters.
            public var billingAddress: AddressInput?
            /// A shipping address the host already knows; same rules as `billingAddress`.
            public var shippingAddress: AddressInput?

            public init() {}
        }

        // MARK: - Internal state

        let driver: CheckoutSessionDriver
        let coordinator: ElementsCoordinator
        let appearance: Appearance
        let walletAuthorizer: any WalletAuthorizing
        let walletMerchantId: String?
        let screenMetrics: ScreenMetricsStore?
        let localize: (String) -> String
        let localeCode: String?
        let addressService: any AddressMetadataService
        let cardRulesService: any CardRulesService

        private var expressElements: [WeakBox<ExpressCheckoutElement>] = []
        /// The group's single card component (created on first `makeCardElement`).
        private var cardElement: CardElement?

        private init(
            driver: CheckoutSessionDriver, coordinator: ElementsCoordinator, appearance: Appearance,
            walletAuthorizer: any WalletAuthorizing, walletMerchantId: String?,
            screenMetrics: ScreenMetricsStore?, localize: @escaping (String) -> String, localeCode: String?,
            addressService: any AddressMetadataService, cardRulesService: any CardRulesService
        ) {
            self.driver = driver
            self.coordinator = coordinator
            self.appearance = appearance
            self.walletAuthorizer = walletAuthorizer
            self.walletMerchantId = walletMerchantId
            self.screenMetrics = screenMetrics
            self.localize = localize
            self.localeCode = localeCode
            self.addressService = addressService
            self.cardRulesService = cardRulesService
            coordinator.onStateChange = { [weak self] state in self?.stateDidChange(state) }
        }

        deinit {
            // The controller must be dismissed (secrets cleared) even if the host never calls `close()`.
            let coordinator = coordinator
            Task { @MainActor in await coordinator.close() }
        }

        // MARK: - Creation

        /// Loads the session once and creates the group.
        ///
        /// - Parameters:
        ///   - checkout: The SDK entry point.
        ///   - sessionId: The session to check out.
        ///   - configuration: Per-session inputs (credentials and host addresses).
        /// - Throws: A `CheckoutError` when the session cannot be loaded or is expired.
        public static func create(
            checkout: SunbayCheckout, sessionId: String, configuration: Configuration = Configuration()
        ) async throws -> CheckoutElements {
            let wiring = checkout.makeUIWiring()
            return try await create(
                controller: wiring.controller, sessionId: sessionId, configuration: configuration,
                appearance: wiring.appearance, walletAuthorizer: wiring.walletAuthorizer,
                walletMerchantId: wiring.walletMerchantId, screenMetrics: wiring.screenMetrics,
                paymentMethodFilter: wiring.paymentMethodFilter, reporter: wiring.diagnostics,
                addressService: wiring.addressMetadataService, localize: wiring.localize,
                localeCode: wiring.localeCode, cardRulesService: wiring.cardRulesService)
        }

        /// Internal dependency-injection seam (tests inject a controller built from a mock backend and a stub wallet).
        static func create(
            controller: CheckoutController, sessionId: String, configuration: Configuration = Configuration(),
            appearance: Appearance = .default, walletAuthorizer: any WalletAuthorizing,
            walletMerchantId: String?, screenMetrics: ScreenMetricsStore? = nil,
            paymentMethodFilter: PaymentMethodFilter = PaymentMethodFilter(),
            reporter: DiagnosticsReporter? = nil,
            addressService: any AddressMetadataService = EmptyAddressMetadataService(),
            localize: @escaping (String) -> String = LocalizationResolver(explicitLocale: nil).localizedNoComment,
            localeCode: String? = nil,
            cardRulesService: any CardRulesService = EmptyCardRulesService()
        ) async throws -> CheckoutElements {
            // Submit runs off the main thread; snapshot the screen up front (refreshed when a view joins a window).
            screenMetrics?.recordMainScreen()
            let driver = CheckoutSessionDriver(
                controller: controller, sessionId: sessionId,
                customerAccessSecret: configuration.customerAccessSecret,
                checkoutClientSecret: configuration.checkoutClientSecret,
                billingAddress: configuration.billingAddress, shippingAddress: configuration.shippingAddress,
                options: .forUI(appearance: appearance, failsWhenNoMethodAvailable: false),
                walletAuthorizer: walletAuthorizer, walletMerchantId: walletMerchantId,
                paymentMethodFilter: paymentMethodFilter)
            switch await driver.loadContext() {
            case let .startFailed(outcome):
                let error: CheckoutError
                if case let .failed(_, loadError) = outcome {
                    error = loadError
                } else {
                    error = CheckoutError(
                        code: "SESSION_LOAD_FAILED", message: "The checkout session could not be loaded.",
                        category: .network, traceId: nil)
                }
                reporter?.error(error, sessionId: sessionId)
                // The load may have left the credential in memory; end the UI session before throwing.
                await driver.dismiss()
                throw error
            case let .ready(context):
                let coordinator = ElementsCoordinator(driver: driver, context: context)
                coordinator.startExpiryTimer()
                return CheckoutElements(
                    driver: driver, coordinator: coordinator, appearance: appearance,
                    walletAuthorizer: walletAuthorizer, walletMerchantId: walletMerchantId,
                    screenMetrics: screenMetrics, localize: localize, localeCode: localeCode,
                    addressService: addressService, cardRulesService: cardRulesService)
            }
        }

        // MARK: - Components

        /// Creates an Express Checkout component (quick wallets).
        public func makeExpressCheckoutElement(
            _ configuration: ExpressCheckoutElement.Configuration = ExpressCheckoutElement.Configuration()
        ) -> ExpressCheckoutElement {
            let element = ExpressCheckoutElement(group: self, configuration: configuration)
            expressElements.removeAll { $0.value == nil }
            expressElements.append(WeakBox(element))
            return element
        }

        /// Creates the bank-card component (saved cards + inline new-card form).
        ///
        /// A group has exactly one card component: a second call returns the same instance and ignores
        /// the new `configuration`.
        public func makeCardElement(_ configuration: CardElement.Configuration = CardElement.Configuration())
            -> CardElement
        {
            if let cardElement { return cardElement }
            let element = CardElement(group: self, configuration: configuration)
            cardElement = element
            return element
        }

        // MARK: - Payment

        /// Display data for the card option currently selected (display only): "Visa ····4242" with the
        /// brand image for a saved card, the brand name alone for a typed card (never any digit). `nil`
        /// when there is no card component, nothing payable is selected, or the typed card is incomplete.
        public var paymentOption: PaymentOptionDisplayData? { cardElement?.paymentOption }

        /// Pays the card component's selection. The amount always comes from the server session.
        ///
        /// Returns `.failed(NO_PAYMENT_OPTION_SELECTED)` when there is no card component or nothing is
        /// selected, and `.failed(CARD_INPUT_INVALID)` (nothing submitted, inline errors shown) when the
        /// new-card form is invalid. After the session ended or a payment settled it returns the stored
        /// outcome again.
        public func confirm() async -> CheckoutOutcome {
            // Validate (and show inline errors) only when this call can actually start a payment; any
            // other state is answered by the coordinator without touching the form.
            let plan: CardElement.ConfirmPlan =
                coordinator.state == .ready ? (cardElement?.prepareConfirm() ?? .nothingSelected) : .nothingSelected
            switch plan {
            case let .action(action):
                return await coordinator.perform(action)
            case .invalidInput:
                // Only reachable while `.ready`: nothing was submitted and the lock was never taken, so
                // answer directly (no `.confirming` flicker, no state-change callbacks).
                return .failed(txnId: nil, error: CheckoutErrors.cardInputInvalid())
            case .nothingSelected:
                return await coordinator.run {
                    .failed(txnId: nil, error: CheckoutErrors.noPaymentOptionSelected())
                }
            }
        }

        /// A UI-independent result lookup (crash / kill recovery); pair it with a `.pending` / `.unknown` outcome.
        public func retrievePayment() async throws -> PaymentSnapshot {
            try await driver.retrievePayment()
        }

        /// Replaces the host billing / shipping addresses used by later payments.
        public func updateAddresses(billing: AddressInput?, shipping: AddressInput?) {
            // Ordered: a `confirm()` issued right after waits for this update before it pays.
            coordinator.updateHostAddresses(billing: billing, shipping: shipping)
        }

        /// Ends the session: disables the components and dismisses the controller (clears the credential).
        public func close() {
            // Blocking new payments is synchronous: a `confirm()` right after `close()` starts nothing.
            guard coordinator.requestClose() else { return }
            Task { @MainActor [coordinator] in await coordinator.finishClose() }
        }

        /// `close()` that can be awaited (test seam).
        func closeAndWait() async {
            await coordinator.close()
        }

        private func stateDidChange(_ state: ElementsCoordinator.State) {
            expressElements.removeAll { $0.value == nil }
            for box in expressElements { box.value?.applyLock(state) }
            cardElement?.applyLock(state)
        }
    }

    private struct WeakBox<T: AnyObject> {
        weak var value: T?
        init(_ value: T) { self.value = value }
    }
#endif
