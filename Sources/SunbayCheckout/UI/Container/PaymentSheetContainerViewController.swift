#if canImport(UIKit)
    import CoreGraphics
    import UIKit

    /// The bottom-sheet container that hosts the host-agnostic `CheckoutContentViewController` (spec §6).
    ///
    /// ## Responsibility boundary
    /// This is the presentation-and-chrome layer: it owns the `UISheetPresentationController`
    /// (grabber, corner radius, detents), hosts the content VC as a child via `addChild`, and
    /// implements `CheckoutContentDelegate` to bridge the content's intents to `PaymentSheet` and
    /// back. It holds **no** business rules — `PaymentSheet.runCheckout` drives `CheckoutController`;
    /// the container only forwards a requested `UserAction` out through `onUserAction` and feeds the
    /// resulting `CheckoutOutcome` back into the content via `applyOutcome(_:)`.
    ///
    /// ## Retry loop (spec §6, design §3.4)
    /// A failed confirm is **not** terminal for the sheet. `runCheckout` is single-shot (one seam →
    /// one confirm → one outcome, preserving the existing `PaymentSheetTests`); the retry loop lives
    /// here: on a `.failed` outcome the content VC's `applyOutcome` shows the inline error and
    /// re-enables editing, the sheet stays open, and the next user confirm produces another
    /// `didRequest` → another `runCheckout` attempt. Each confirm maps to exactly one attempt; there
    /// is no blind resubmit (that invariant is enforced in Core by `CheckoutController`).
    ///
    /// ## Delegate bridge
    /// `didRequest` is forwarded to `onUserAction` (wired by `PaymentSheet.present` into the
    /// `runCheckout` seam). `didFinishWith` dismisses the sheet and resolves the presentation via
    /// `onFinish`. `contentDidRequestCancel` and an interactive pull-down both resolve to `.canceled`
    /// (via `onFinish`). `didChangeProcessing(true)` sets `isModalInPresentation = true` to block the
    /// pull-down while a confirm is in flight (payment truth = server-confirmed, AGENTS.md §2.5).
    /// `didChangeState` is forwarded to `onStateChange` → the public `PaymentSheet.onStateChange`.
    ///
    /// iOS-only: gated by `#if canImport(UIKit)`. iOS 15 minimum — all iOS 16+ sheet APIs
    /// (`.custom` detent, `invalidateDetents()`) are guarded by `if #available(iOS 16, *)`.
    final class PaymentSheetContainerViewController: UIViewController, CheckoutContentDelegate {
        // MARK: - Callbacks (wired by PaymentSheet)

        /// Called when the content requests a confirm action; the present layer bridges it into the
        /// `runCheckout` seam. Invoked on the main actor.
        var onUserAction: ((PaymentSheet.UserAction) -> Void)?

        /// Called exactly once when the presentation resolves to a terminal/cancel outcome (after the
        /// sheet begins dismissing). The present layer resumes its continuation with this outcome.
        var onFinish: ((CheckoutOutcome) -> Void)?

        /// Forwards the coarse presentation state to `PaymentSheet.onStateChange`.
        var onStateChange: ((CheckoutPresentationState) -> Void)?

        // MARK: - Injected

        private let content: CheckoutContentViewController
        private let appearance: ResolvedAppearance
        private let colorScheme: Appearance.ColorScheme

        /// Guards `onFinish` so a terminal outcome and a pull-down cancel cannot both fire.
        private var didFinish = false

        /// The latest content height reported by the content VC (drives the iOS 16+ adaptive detent).
        private var preferredContentHeight: CGFloat = 0

        // MARK: - Init

        /// Creates the container around a content VC.
        ///
        /// - Parameters:
        ///   - content: The host-agnostic content VC to host as a child.
        ///   - appearance: The resolved appearance (corner radius + color scheme).
        ///   - colorScheme: The merchant color-scheme preference (drives `overrideUserInterfaceStyle`).
        init(
            content: CheckoutContentViewController,
            appearance: ResolvedAppearance,
            colorScheme: Appearance.ColorScheme
        ) {
            self.content = content
            self.appearance = appearance
            self.colorScheme = colorScheme
            super.init(nibName: nil, bundle: nil)
            content.delegate = self
            modalPresentationStyle = .pageSheet
        }

        @available(*, unavailable)
        required init?(coder: NSCoder) {
            fatalError("init(coder:) is not supported")
        }

        // MARK: - Lifecycle

        override func viewDidLoad() {
            super.viewDidLoad()
            view.backgroundColor = appearance.background
            applyColorScheme()
            embedContent()
            configurePresentationDetents()
            // Receive the interactive pull-down callback (→ `.canceled`).
            presentationController?.delegate = self
        }

        /// Maps the merchant `colorScheme` to `overrideUserInterfaceStyle` on the container root and
        /// the content (so the whole sheet follows the preference; `.automatic` follows the system).
        private func applyColorScheme() {
            let style: UIUserInterfaceStyle
            switch colorScheme {
            case .automatic: style = .unspecified
            case .light: style = .light
            case .dark: style = .dark
            }
            overrideUserInterfaceStyle = style
            content.overrideUserInterfaceStyle = style
        }

        /// Hosts the content VC as a child, pinned to the container's safe area.
        private func embedContent() {
            addChild(content)
            content.view.translatesAutoresizingMaskIntoConstraints = false
            view.addSubview(content.view)
            NSLayoutConstraint.activate([
                content.view.topAnchor.constraint(equalTo: view.topAnchor),
                content.view.leadingAnchor.constraint(equalTo: view.leadingAnchor),
                content.view.trailingAnchor.constraint(equalTo: view.trailingAnchor),
                content.view.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            ])
            content.didMove(toParent: self)
        }

        // MARK: - Sheet presentation

        /// Configures the `UISheetPresentationController`: grabber on, corner radius from appearance,
        /// and detents (iOS 16+ adaptive `.custom`, iOS 15 `.medium()`/`.large()` + internal scroll).
        private func configurePresentationDetents() {
            guard let sheet = sheetPresentationController else { return }
            sheet.prefersGrabberVisible = true
            sheet.preferredCornerRadius = appearance.cornerRadius
            if #available(iOS 16.0, *) {
                sheet.detents = [adaptiveDetent(), .large()]
                sheet.prefersScrollingExpandsWhenScrolledToEdge = false
            } else {
                // iOS 15 fallback: fixed detents; the content VC's own scroll view handles overflow.
                sheet.detents = [.medium(), .large()]
            }
        }

        /// Builds the iOS 16+ adaptive `.custom` detent from the reported content height, clamped to
        /// the sheet's maximum so an overlong form still expands to `.large` via scrolling.
        @available(iOS 16.0, *)
        private func adaptiveDetent() -> UISheetPresentationController.Detent {
            .custom(identifier: .init("sunbay.adaptive")) { [weak self] context in
                guard let self, self.preferredContentHeight > 0 else {
                    return context.maximumDetentValue * 0.5
                }
                return min(self.preferredContentHeight, context.maximumDetentValue)
            }
        }

        // MARK: - CheckoutContentDelegate

        func content(_ content: CheckoutContentViewController, didRequest action: PaymentSheet.UserAction) {
            onUserAction?(action)
        }

        func contentDidRequestCancel(_ content: CheckoutContentViewController) {
            finish(with: .canceled, dismissSheet: true)
        }

        func content(_ content: CheckoutContentViewController, didFinishWith outcome: CheckoutOutcome) {
            finish(with: outcome, dismissSheet: true)
        }

        func content(_ content: CheckoutContentViewController, didChangeProcessing isProcessing: Bool) {
            // Block the interactive pull-down while a confirm is in flight (no cancel mid-payment).
            isModalInPresentation = isProcessing
        }

        func content(_ content: CheckoutContentViewController, didUpdateContentHeight height: CGFloat) {
            preferredContentHeight = height
            // Re-evaluate the adaptive detent to fit the new content height (iOS 16+ only).
            if #available(iOS 16.0, *) {
                sheetPresentationController?.animateChanges {
                    sheetPresentationController?.invalidateDetents()
                }
            }
        }

        func content(_ content: CheckoutContentViewController, didChangeState state: CheckoutPresentationState) {
            onStateChange?(state)
        }

        // MARK: - Finish

        /// Resolves the presentation exactly once, optionally dismissing the sheet first.
        private func finish(with outcome: CheckoutOutcome, dismissSheet: Bool) {
            guard !didFinish else { return }
            didFinish = true
            if dismissSheet {
                dismiss(animated: true)
            }
            onFinish?(outcome)
        }
    }

    // MARK: - Interactive-dismiss bridge

    extension PaymentSheetContainerViewController: UIAdaptivePresentationControllerDelegate {
        /// UIKit calls this after a user-driven pull-down completes; route it to `.canceled`.
        ///
        /// `didFinishWith` dismisses programmatically and sets `didFinish` first, so this only
        /// resolves a user-initiated pull-down. `isModalInPresentation` already blocks the pull-down
        /// during processing, so a mid-payment cancel cannot reach here.
        func presentationControllerDidDismiss(_ presentationController: UIPresentationController) {
            finish(with: .canceled, dismissSheet: false)
        }
    }
#endif
