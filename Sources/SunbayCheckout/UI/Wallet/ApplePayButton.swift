#if canImport(UIKit)
    import UIKit

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
    /// Tap → `WalletAuthorizing.authorize(...)` to get the encrypted wallet token →
    /// `controller.confirmWallet(token:)` → the backend-confirmed terminal state is mapped to a
    /// `CheckoutOutcome` → `onResult` fires on the main thread. Wallet authorization success ≠
    /// transaction success (§3.2): the real conclusion comes from `confirmWallet`'s outcome.
    ///
    /// ## Security (§5)
    /// The wallet token `Data` flows only along the single path `authorize → confirmWallet`, and
    /// **never** enters `onResult`, logs, or any persistence. On cancel / authorization failure,
    /// no `onResult` is produced (keeping the control tappable again).
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
        ///
        /// - Note: The controller uses the backend services held by the `checkout` instance: if
        ///   the host injected real/mock services via
        ///   `SunbayCheckout(configuration:paymentService:cofService:)`, the button uses them;
        ///   otherwise it falls back to the shared fail-closed `Unconfigured*` defaults (until
        ///   the §7/§8 contract is defined).
        public convenience init(
            checkout: SunbayCheckout,
            sessionId: String,
            style: ApplePayButtonStyle = .automatic
        ) {
            let webAuthOpener = WebAuthOpener()
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
                style: style
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
            style: ApplePayButtonStyle = .automatic
        ) {
            self.controller = controller
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
                    customerAccessSecret: nil
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
                    // Wallet token: flows only between authorize → confirmWallet, never enters onResult/logs (§5).
                    let token = try await authorizer.authorize(
                        amount: amount,
                        merchantId: merchantId
                    )
                    outcome = await controller.confirmWallet(token: token)
                } catch {
                    // Authorization canceled / failed: produce no transaction conclusion, the control stays tappable again.
                    return
                }
                self?.onMain { self?.onResult?(outcome) }
            }
        }

        // MARK: - Appearance

        /// Applies the minimal color scheme (follows the light/dark scheme). Does not hardcode business colors; only this control's own visuals.
        private func configureAppearance(_ style: ApplePayButtonStyle) {
            layer.cornerRadius = 8
            let (bg, fg): (UIColor, UIColor)
            switch style {
            case .black:
                (bg, fg) = (.black, .white)
            case .white:
                (bg, fg) = (.white, .black)
                layer.borderWidth = 1
                layer.borderColor = UIColor.separator.cgColor
            case .automatic:
                // Follow the trait: dark → white background/black text, light → black background/white text (label/systemBackground adapt automatically).
                (bg, fg) = (.label, .systemBackground)
            }
            backgroundColor = bg
            tintColor = fg
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
