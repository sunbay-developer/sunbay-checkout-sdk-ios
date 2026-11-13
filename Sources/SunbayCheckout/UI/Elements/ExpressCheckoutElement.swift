#if canImport(UIKit)
    import UIKit

    /// The quick-wallet component of `CheckoutElements` (today only Apple Pay): a self-sizing view the
    /// merchant places in its own layout. A tap pays immediately.
    ///
    /// ## Availability
    /// `isAvailable` is known as soon as the element exists (the session is already loaded by
    /// `CheckoutElements.create`): the device can pay, a merchant id is configured, the session offers
    /// Apple Pay, the global `PaymentMethodFilter` does not hide it, `Appearance.expressPosition` is not
    /// `.off`, and `Configuration.methods` allows it. An unavailable element renders a zero-height view.
    /// `onAvailabilityChange` is delivered once, asynchronously, with the initial value (so a handler
    /// assigned right after creation still receives it). A handler assigned after an `await` (or any
    /// suspension point) following creation may miss that callback: `isAvailable` is authoritative, so
    /// read it directly instead of relying on the callback.
    ///
    /// ## Result
    /// A tap presents the Apple Pay sheet; each authorized token is confirmed while the sheet is still
    /// open, and the final `CheckoutOutcome` is reported through `onResult` on the main actor. The user
    /// dismissing the sheet maps to `.canceled`; an authorization failure maps to `.failed`. The wallet
    /// token flows only along `authorize → confirm` and never enters `onResult`, logs or any property.
    @MainActor
    public final class ExpressCheckoutElement {
        /// A wallet that can appear in the express component.
        public enum ExpressMethod: Sendable, Hashable {
            case applePay
        }

        /// Per-component settings; `nil` means "follow the global checkout configuration". The global
        /// `PaymentMethodFilter` and provider availability always win over these settings.
        public struct Configuration {
            /// The wallets to show; `nil` = every available wallet, e.g. `[.applePay]`.
            public var methods: Set<ExpressMethod>?
            /// The Apple Pay button wording; `nil` = `Appearance.applePayButtonType`.
            public var buttonType: ApplePayButtonType?
            /// The Apple Pay button color; `nil` = `Appearance.applePayButtonStyle`.
            public var buttonStyle: Appearance.ApplePayButtonStyle?

            public init() {}
        }

        /// The element's self-sizing view (zero height while unavailable).
        public var view: UIView { container }

        /// Whether the element has a wallet to show.
        public private(set) var isAvailable: Bool

        /// Called once with the initial availability, on the main actor, right after creation. A handler
        /// assigned after an `await` misses the callback; `isAvailable` is authoritative.
        public var onAvailabilityChange: ((Bool) -> Void)?

        /// Called with the outcome after a tap's payment completes.
        public var onResult: ((CheckoutOutcome) -> Void)?

        private let group: CheckoutElements
        private let container = ExpressElementContainerView()
        private var expressView: ExpressCheckoutView?

        init(group: CheckoutElements, configuration: Configuration) {
            self.group = group
            let context = group.coordinator.context
            let visibleByFilter = context.visibleEntries.contains {
                PaymentMethodModel.logicalKey($0) == "APPLE_PAY"
            }
            let allowedByConfiguration = configuration.methods?.contains(.applePay) ?? true
            let availability = ApplePayAvailability.evaluate(
                session: context.session, hiddenByFilter: !visibleByFilter,
                authorizer: group.walletAuthorizer, merchantId: group.walletMerchantId)
            isAvailable = allowedByConfiguration && group.appearance.expressPosition != .off
                && availability.available

            container.onMoveToWindow = { [weak group] screen in
                group?.screenMetrics?.recordMainScreen(screen)
            }
            if isAvailable {
                let express = ExpressCheckoutView(
                    appearance: ResolvedAppearance.resolve(group.appearance), showsDivider: false,
                    buttonType: configuration.buttonType, buttonStyle: configuration.buttonStyle)
                express.onApplePayTapped = { [weak self] in self?.simulateTap() }
                express.translatesAutoresizingMaskIntoConstraints = false
                container.addSubview(express)
                NSLayoutConstraint.activate([
                    express.topAnchor.constraint(equalTo: container.topAnchor),
                    express.bottomAnchor.constraint(equalTo: container.bottomAnchor),
                    express.leadingAnchor.constraint(equalTo: container.leadingAnchor),
                    express.trailingAnchor.constraint(equalTo: container.trailingAnchor),
                ])
                expressView = express
            } else {
                container.isHidden = true
            }
            applyLock(group.coordinator.state)

            let initial = isAvailable
            Task { @MainActor [weak self] in self?.onAvailabilityChange?(initial) }
        }

        /// Starts the tap flow (also the test seam for a button tap).
        func simulateTap() {
            Task { @MainActor [weak self] in await self?.handleTap() }
        }

        /// Disables the button while a payment is in flight or the session has ended.
        func applyLock(_ state: ElementsCoordinator.State) {
            let enabled = state == .ready
            expressView?.isUserInteractionEnabled = enabled
            expressView?.alpha = enabled ? 1 : 0.5
        }

        /// Authorize → confirm inside the shared payment lock, then report the outcome.
        private func handleTap() async {
            guard isAvailable, let merchantId = group.walletMerchantId else { return }
            let session = group.coordinator.context.session
            let authorizer = group.walletAuthorizer
            let driver = group.driver
            let outcome = await group.coordinator.run {
                do {
                    // No SDK address form on this path: PassKit collects the contacts the session asks for.
                    let contacts = await driver.walletContactRequest()
                    // The token is confirmed while the Apple Pay sheet is still open; it flows only into
                    // the confirm call, never into onResult/logs.
                    return try await authorizer.authorize(
                        amount: session.amount, merchantId: merchantId, merchantName: session.merchantName,
                        params: session.applePayParams, contacts: contacts
                    ) { authorization in
                        switch await driver.execute(
                            .confirmWallet(authorization, billingFormShown: false, shippingFormShown: false))
                        {
                        case let .outcome(outcome), let .startFailed(outcome): return outcome
                        }
                    }
                } catch {
                    // Authorization ended without a token: a user cancel is `.canceled`, anything else
                    // is an authorization failure. Nothing was submitted; no sensitive data is involved.
                    if let checkoutError = error as? CheckoutError, checkoutError.code == "WALLET_CANCELED" {
                        return .canceled
                    }
                    let checkoutError = (error as? CheckoutError) ?? CheckoutError(
                        code: "WALLET_AUTH_FAILED", message: "Apple Pay authorization failed.",
                        category: .runtime, traceId: nil)
                    return .failed(txnId: nil, error: checkoutError)
                }
            }
            onResult?(outcome)
        }
    }

    /// The element's host view: collapses to zero height when hidden and snapshots the screen metrics
    /// whenever it joins a window.
    final class ExpressElementContainerView: UIView {
        var onMoveToWindow: ((UIScreen) -> Void)?

        override func didMoveToWindow() {
            super.didMoveToWindow()
            if let screen = window?.screen { onMoveToWindow?(screen) }
        }

        override var intrinsicContentSize: CGSize {
            isHidden ? CGSize(width: UIView.noIntrinsicMetric, height: 0) : super.intrinsicContentSize
        }
    }
#endif
