#if canImport(UIKit)
    import UIKit

    #if canImport(PassKit)
        import PassKit
    #endif

    /// A standalone Apple Pay button (L3, product-spec §2.3).
    ///
    /// ## Positioning
    /// A long-lived UIKit control: the host places it in its own UI, and tapping it starts
    /// Apple Pay. It uses only the two Core capabilities `WalletAuthorizing` +
    /// `CheckoutController`; it **does not touch the card form and holds no business rules**
    /// (all business orchestration lives in `CheckoutController`). Events use closure callbacks
    /// (the iOS convention, a continuous event source, §2.5) rather than a one-shot async
    /// return.
    ///
    /// ## Availability (isAvailable)
    /// `available = backend allows ∩ device capable ∩ merchant-id configured`:
    /// - **Device capable**: `WalletAuthorizing.canMakePayments()` (device-related, known at construction).
    /// - **merchant-id configured**: `resolveMerchantId(configured:sessionProvided:)` is non-nil
    ///   (host configuration takes precedence over session delivery; known at construction).
    /// - **Backend allows**: whether, after `CheckoutController` loads the session, its `methods`
    ///   contains `.applePay` (**asynchronous**, known only after the session finishes loading).
    ///
    /// At construction it first provides an initial value with "backend allows = false"; it then
    /// loads the session in the background, recomputes availability once loading completes, and,
    /// if it changed, fires `onAvailabilityChange` on the main thread.
    ///
    /// ## Result (onResult)
    /// Tap → `WalletAuthorizing.authorize(...)` presents the Apple Pay sheet; each authorized token is
    /// confirmed via `controller.confirmWallet(token:)` while the sheet is still open, the sheet shows
    /// the backend-derived status, and once it closes the final `CheckoutOutcome` fires `onResult` on
    /// the main thread. Wallet authorization success ≠
    /// transaction success (§3.2): the real conclusion comes from `confirmWallet`'s outcome. The user
    /// dismissing the sheet maps to `.canceled`; an authorization failure maps to `.failed`; both fire
    /// `onResult` and leave the control tappable again.
    ///
    /// ## Security (§5)
    /// The wallet token `Data` flows only along the single path `authorize → confirmWallet`, and
    /// **never** enters `onResult`, logs, or any persistence. A cancel / authorization failure carries
    /// no token and no sensitive data in its `onResult` outcome.
    ///
    /// iOS-only: the whole thing is `#if canImport(UIKit)`; it does not compile under the macOS host.
    public final class ApplePayButton: UIControl {
        /// Button color style (follows the light/dark scheme; kept minimal).
        public enum ApplePayButtonStyle: Sendable {
            /// Follow the current trait (light → black background, dark → white background).
            case automatic
            /// Fixed black background, white text.
            case black
            /// Fixed white background, black text (with a stroke).
            case white
        }

        // MARK: - Public events (closures, continuous event source, §2.5)

        /// Called when availability changes (on the main thread). Carries the latest `isAvailable`.
        public var onAvailabilityChange: ((Bool) -> Void)?

        /// The payment-result callback for one tap (on the main thread). Carries the backend-confirmed `CheckoutOutcome`.
        public var onResult: ((CheckoutOutcome) -> Void)?

        /// Whether it is currently available (see the three-factor intersection in the type description). Read-only.
        public private(set) var isAvailable: Bool {
            didSet {
                guard oldValue != isAvailable else { return }
                let available = isAvailable
                onMain { [weak self] in
                    self?.isEnabled = available
                    self?.onAvailabilityChange?(available)
                }
            }
        }

        // MARK: - Dependencies (injected via the internal init; the public init assembles the real implementations)

        private let controller: CheckoutController
        private let walletAuthorizer: any WalletAuthorizing
        private let sessionId: String
        /// The amount for this payment; overwritten with the session amount once the session finishes loading (may be a nil placeholder at construction).
        private var amount: Amount?
        /// The resolved Apple Pay merchant id (host configuration takes precedence); nil means not configured → not available.
        private let resolvedMerchantId: String?

        /// Whether the device is capable (fixed at construction).
        private let deviceCapable: Bool
        /// Whether the backend allows Apple Pay (updated after the session loads).
        private var backendAllowed = false

        /// The requested color style; retained so `.automatic` can refresh on trait changes.
        private let style: ApplePayButtonStyle

        #if canImport(PassKit)
            /// The official PassKit button rendered as a pinned subview (owns its own appearance).
            private var paymentButton: PKPaymentButton?
        #endif

        /// Client secret issued by the host backend with the session (optional); memory only, never logged.
        /// Kept across failed / unknown attempts so a second tap still carries it; cleared on success / dismiss / expiry.
        private let checkoutClientSecret: String?

        // MARK: - Public initialization (assembles the real dependencies)

        /// Constructs the button from a `SunbayCheckout` entry point and a session identifier (the public entry point used by the host).
        ///
        /// Assembles a real `CheckoutController` through the `SunbayCheckout.makeController`
        /// seam (injecting a real `ActionHandler` + `WebAuthOpener`), and uses the real PassKit
        /// `WalletAuthorizer` as the wallet capability. The merchant-id is taken from the host
        /// configuration (preferred) or the session delivery.
        ///
        /// - Parameters:
        ///   - checkout: The SDK public entry point (holding the host configuration).
        ///   - sessionId: The session identifier to check out.
        ///   - style: Button color style; defaults to `.automatic`.
        ///   - checkoutClientSecret: Client secret issued by the host backend together with the session (optional); kept in memory only, never logged.
        ///
        /// - Note: The controller uses the backend services held by the `checkout` instance: if
        ///   the host injected real/mock services via
        ///   `SunbayCheckout(configuration:paymentService:cofService:)`, the button uses them;
        ///   otherwise it talks to the real Sunbay backend for the configured environment.
        public convenience init(
            checkout: SunbayCheckout,
            sessionId: String,
            style: ApplePayButtonStyle = .automatic,
            checkoutClientSecret: String? = nil
        ) {
            let webAuthOpener = WebAuthOpener()
            // UIView inits run on the main actor: snapshot the screen here so the (off-main) submit path can read it.
            checkout.screenMetrics.recordMainScreen()
            let controller = checkout.makeController(
                credentials: CredentialStore(),
                actionHandler: ActionHandler(webAuthOpener: webAuthOpener)
            )
            self.init(
                controller: controller,
                walletAuthorizer: WalletAuthorizer(),
                sessionId: sessionId,
                configuredMerchantId: checkout.configuration.applePayMerchantId,
                amount: nil,
                style: style,
                checkoutClientSecret: checkoutClientSecret
            )
        }

        // MARK: - Internal initialization (dependency-injection seam, for mocks in unit tests)

        /// The internal initializer with injected dependencies (unit tests inject a mock controller and a mock wallet capability through it).
        ///
        /// - Parameters:
        ///   - controller: The payment orchestrator (may be a real actor assembled from a mock backend).
        ///   - walletAuthorizer: The wallet capability (device availability + authorize to get the token).
        ///   - sessionId: The session identifier.
        ///   - configuredMerchantId: The host-configured merchant id (may be nil).
        ///   - amount: The amount for this payment; defaults to nil, overwritten with the session amount after the session loads.
        ///   - style: Color style.
        init(
            controller: CheckoutController,
            walletAuthorizer: any WalletAuthorizing,
            sessionId: String,
            configuredMerchantId: String?,
            amount: Amount? = nil,
            style: ApplePayButtonStyle = .automatic,
            checkoutClientSecret: String? = nil
        ) {
            self.controller = controller
            self.checkoutClientSecret = checkoutClientSecret
            self.walletAuthorizer = walletAuthorizer
            self.sessionId = sessionId
            self.amount = amount
            // The session does not deliver a merchant id (the Core model has no such field) → pass nil for sessionProvided.
            self.resolvedMerchantId = resolveMerchantId(
                configured: configuredMerchantId,
                sessionProvided: nil
            )
            self.deviceCapable = walletAuthorizer.canMakePayments()
            self.isAvailable = false // Not available before "backend allows" is known.
            self.style = style

            super.init(frame: .zero)

            configureAppearance(style)
            addTarget(self, action: #selector(handleTap), for: .touchUpInside)
            // Initial value: "backend allows" not yet known → not available.
            isEnabled = false

            // Load the session in the background, and recompute availability once complete.
            Task { [weak self] in
                await self?.loadSessionAndRefreshAvailability()
            }
        }

        @available(*, unavailable)
        required init?(coder: NSCoder) {
            fatalError("init(coder:) is not supported; use init(checkout:sessionId:style:)")
        }

        // MARK: - Availability computation

        /// Loads the session and refreshes availability (in the background).
        ///
        /// On successful load → `backendAllowed = methods.contains(.applePay)`, and overwrite the
        /// payment amount with the session amount; on failed load → keep backend allows = false
        /// (not available). Then recompute and (when changed) call back.
        private func loadSessionAndRefreshAvailability() async {
            do {
                let session = try await controller.start(
                    sessionId: sessionId,
                    customerAccessSecret: nil,
                    checkoutClientSecret: checkoutClientSecret
                )
                backendAllowed = session.methods.contains(.applePay)
                amount = session.amount
            } catch {
                backendAllowed = false
            }
            recomputeAvailability()
        }

        /// Recomputes `isAvailable` as the three-factor intersection (its `didSet` is responsible for the main-thread callback when it changes).
        private func recomputeAvailability() {
            isAvailable = deviceCapable && backendAllowed && (resolvedMerchantId != nil)
        }

        // MARK: - Tap → authorize → confirm

        /// Handles a tap: authorize to get the token → `confirmWallet` → main-thread `onResult` callback.
        @objc private func handleTap() {
            guard isAvailable, let merchantId = resolvedMerchantId, let amount else { return }
            let authorizer = walletAuthorizer
            let controller = controller
            Task { [weak self] in
                let outcome: CheckoutOutcome
                do {
                    // The token is confirmed while the Apple Pay sheet is still open; the sheet shows
                    // success/failure only after the backend outcome is known. The token flows only
                    // into confirmWallet, never into onResult/logs (§5).
                    outcome = try await authorizer.authorize(
                        amount: amount,
                        merchantId: merchantId
                    ) { token in
                        await controller.confirmWallet(token: token)
                    }
                } catch {
                    // Authorization ended without a token. Distinguish a user cancel (→ `.canceled`,
                    // NOT a failure) from an authorization failure (→ `.failed`). The PassKit authorizer
                    // throws a `CheckoutError` with code `WALLET_CANCELED` on cancel. Either way nothing
                    // was submitted; the control stays tappable. No sensitive data is involved.
                    if let checkoutError = error as? CheckoutError, checkoutError.code == "WALLET_CANCELED" {
                        outcome = .canceled
                    } else {
                        let checkoutError = (error as? CheckoutError) ?? CheckoutError(
                            code: "WALLET_AUTH_FAILED",
                            message: "Apple Pay authorization failed.",
                            category: .runtime,
                            traceId: nil
                        )
                        outcome = .failed(txnId: nil, error: checkoutError)
                    }
                }
                self?.onMain { self?.onResult?(outcome) }
            }
        }

        // MARK: - Appearance

        /// Maps an `ApplePayButtonStyle` + current interface trait to a `PKPaymentButtonStyle` (pure).
        ///
        /// - `.black` → `.black`
        /// - `.white` → `.white`
        /// - `.automatic` → by trait: `.dark` → `.white`, otherwise `.black`
        ///
        /// Both resolved styles (`.black` / `.white`) exist since iOS 8.3, so the mapping is safe at
        /// the iOS 15 minimum with no downgrade needed.
        #if canImport(PassKit)
            static func pkStyle(
                for style: ApplePayButtonStyle,
                trait: UIUserInterfaceStyle
            ) -> PKPaymentButtonStyle {
                switch style {
                case .black:
                    return .black
                case .white:
                    return .white
                case .automatic:
                    return trait == .dark ? .white : .black
                }
            }
        #endif

        /// Renders the official PassKit `PKPaymentButton` as a pinned subview filling the control.
        ///
        /// `PKPaymentButton` owns its own HIG-compliant appearance (no business colors hardcoded);
        /// its tap is forwarded to the same `handleTap` path (authorize → confirmWallet → onResult).
        private func configureAppearance(_ style: ApplePayButtonStyle) {
            #if canImport(PassKit)
                rebuildPaymentButton(style)
            #endif
        }

        #if canImport(PassKit)
            /// Builds (or rebuilds) the `PKPaymentButton` for the given style and pins it to the control.
            private func rebuildPaymentButton(_ style: ApplePayButtonStyle) {
                paymentButton?.removeFromSuperview()

                let pkStyle = Self.pkStyle(
                    for: style,
                    trait: traitCollection.userInterfaceStyle
                )
                let button = PKPaymentButton(paymentButtonType: .plain, paymentButtonStyle: pkStyle)
                button.translatesAutoresizingMaskIntoConstraints = false
                // Forward the PassKit button tap to the same tap path used by the control itself.
                button.addTarget(self, action: #selector(handleTap), for: .touchUpInside)
                button.isUserInteractionEnabled = false // Let the enclosing UIControl gate taps via isEnabled.
                addSubview(button)
                NSLayoutConstraint.activate([
                    button.topAnchor.constraint(equalTo: topAnchor),
                    button.bottomAnchor.constraint(equalTo: bottomAnchor),
                    button.leadingAnchor.constraint(equalTo: leadingAnchor),
                    button.trailingAnchor.constraint(equalTo: trailingAnchor),
                ])
                paymentButton = button
            }
        #endif

        /// Refreshes the `.automatic` style when the interface trait (light/dark) changes.
        override public func traitCollectionDidChange(_ previousTraitCollection: UITraitCollection?) {
            super.traitCollectionDidChange(previousTraitCollection)
            #if canImport(PassKit)
                guard style == .automatic else { return }
                guard traitCollection.userInterfaceStyle
                    != previousTraitCollection?.userInterfaceStyle
                else { return }
                rebuildPaymentButton(style)
            #endif
        }

        // MARK: - Main-thread utility

        /// Executes a closure on the main thread (executes synchronously if already on the main thread, avoiding an extra hop).
        private func onMain(_ work: @escaping () -> Void) {
            if Thread.isMainThread {
                work()
            } else {
                DispatchQueue.main.async(execute: work)
            }
        }
    }
#endif
