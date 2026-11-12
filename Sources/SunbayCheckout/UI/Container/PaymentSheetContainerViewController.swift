#if canImport(UIKit)
    import CoreGraphics
    import UIKit

    /// The bottom-sheet container that hosts the host-agnostic `CheckoutContentViewController` (spec §6).
    ///
    /// ## Responsibility boundary
    /// This is the presentation-and-chrome layer: it picks the presentation style (custom iPhone
    /// bottom sheet vs. system form sheet), hosts the content VC as a child via `addChild`, and
    /// implements `CheckoutContentDelegate` to bridge the content's intents to `PaymentSheet` and
    /// back. It holds **no** business rules — `PaymentSheet.runCheckout` drives `CheckoutController`;
    /// the container only forwards a requested `UserAction` out through `onUserAction` and feeds the
    /// resulting `CheckoutOutcome` back into the content via `applyOutcome(_:)`.
    ///
    /// ## Presentation (Stripe parity)
    /// - iPhone / any non-pad/mac/vision idiom: `.custom` presentation with
    ///   `BottomSheetPresentationController` (full-width, edge-attached, own dimming view, top-only
    ///   corners, explicit height from `Appearance.sheetSizing`). No grabber, no drag-to-dismiss.
    /// - iPad / Mac / visionOS: the system `.formSheet`, `isModalInPresentation = true`; the system
    ///   sizes it, so `sheetSizing` does not apply there.
    /// The style and the (retained) transitioning delegate are configured in `init`, i.e. before
    /// `present(_:animated:)`.
    ///
    /// ## Retry loop (spec §6, design §3.4)
    /// A failed confirm is **not** terminal for the sheet. `runCheckout` is single-shot (one seam →
    /// one confirm → one outcome, preserving the existing `PaymentSheetTests`); the retry loop lives
    /// here: on a `.failed` outcome the content VC's `applyOutcome` shows the inline error and
    /// re-enables editing, the sheet stays open, and the next user confirm produces another
    /// `didRequest` → another `runCheckout` attempt. Each confirm maps to exactly one attempt; there
    /// is no blind resubmit (that invariant is enforced in Core by `CheckoutController`).
    ///
    /// ## Dismissal rules
    /// `didRequest` is forwarded to `onUserAction`. `didFinishWith` dismisses the sheet and resolves
    /// the presentation via `onFinish`. The header ✕, a backdrop tap, the VoiceOver Escape gesture and
    /// an outside tap on the form sheet all resolve to `.canceled` through the same path, and are
    /// **ignored** while a confirm is in flight (`processing`) or the success animation runs
    /// (`succeeded`) — payment truth = server-confirmed (AGENTS.md §2.5). `didChangeState` is forwarded
    /// to `onStateChange` → the public `PaymentSheet.onStateChange`.
    ///
    /// iOS-only: gated by `#if canImport(UIKit)`.
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

        /// Performs a saved-card delete (wired by `PaymentSheet` to `CheckoutController`).
        var onDeleteSavedCard: (@Sendable (String) async -> Result<Void, CheckoutError>)?

        // MARK: - Injected

        private let content: CheckoutContentViewController
        private let appearance: ResolvedAppearance
        private let colorScheme: Appearance.ColorScheme

        /// Guards `onFinish` so a terminal outcome and a pull-down cancel cannot both fire.
        private var didFinish = false

        /// The latest total content height reported by the content VC (drives the sheet height).
        private var preferredContentHeight: CGFloat = 0

        /// Whether a confirm is in flight (set from `didChangeProcessing`).
        private var isProcessing = false
        /// Whether the success animation is running / done (`didChangeState(.succeeded)`).
        private var isSucceeded = false

        /// The presentation style resolved for this device.
        let presentationStyle: BottomSheetPresentationStyle

        /// Retained: `UIViewController.transitioningDelegate` is weak.
        private var sheetTransitioningDelegate: BottomSheetTransitioningDelegate?

        /// How a dismissal is performed once a cancel is accepted. Overridable by tests, which cannot
        /// present the container.
        var performDismiss: () -> Void = {}

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
            presentationStyle = BottomSheetPresentationStyle.resolve(
                idiom: UIDevice.current.userInterfaceIdiom)
            super.init(nibName: nil, bundle: nil)
            content.delegate = self
            performDismiss = { [weak self] in self?.dismiss(animated: true) }
            configurePresentation()
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
            if presentationStyle == .formSheet {
                // Outside taps on the form sheet are routed through `presentationControllerShouldDismiss`.
                presentationController?.delegate = self
            }
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

        /// Sets the modal presentation style and (for the iPhone bottom sheet) the retained
        /// transitioning delegate. Called from `init`, so it is in place before `present`.
        private func configurePresentation() {
            switch presentationStyle {
            case .formSheet:
                modalPresentationStyle = .formSheet
                isModalInPresentation = true
            case .customBottomSheet:
                modalPresentationStyle = .custom
                modalPresentationCapturesStatusBarAppearance = true
                let delegate = BottomSheetTransitioningDelegate(
                    makeLayout: { [weak self] in
                        BottomSheetLayout(
                            policy: BottomSheetGeometry.Policy(self?.appearance.sheetSizing ?? .init()),
                            appearanceCornerRadius: self?.appearance.cornerRadius ?? 0,
                            contentHeight: self?.preferredContentHeight ?? 0)
                    },
                    onBackdropTap: { [weak self] in self?.requestCancel() },
                    onKeyboardSettled: { [weak self] in self?.content.scrollFocusedFieldIntoView() })
                sheetTransitioningDelegate = delegate
                transitioningDelegate = delegate
            }
        }

        private var bottomSheetController: BottomSheetPresentationController? {
            presentationController as? BottomSheetPresentationController
        }

        /// Whether the sheet is currently editable, i.e. a cancel is allowed.
        var canCancel: Bool { !isProcessing && !isSucceeded && !didFinish }

        /// Backdrop tap / Escape / outside tap: cancels the whole sheet when editable, else ignores it.
        /// - Returns: whether the cancel was accepted.
        @discardableResult
        func requestCancel() -> Bool {
            guard canCancel else { return false }
            finish(with: .canceled, dismissSheet: true)
            return true
        }

        /// VoiceOver two-finger Z: same rule as a backdrop tap.
        override func accessibilityPerformEscape() -> Bool {
            requestCancel()
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
            // No backdrop / Escape cancel while a confirm is in flight (payment truth = server-confirmed).
            self.isProcessing = isProcessing
        }

        func content(_ content: CheckoutContentViewController, didUpdateContentHeight height: CGFloat) {
            preferredContentHeight = height
            bottomSheetController?.setContentHeight(height)
        }

        func content(_ content: CheckoutContentViewController, didChangeState state: CheckoutPresentationState) {
            isSucceeded = (state == .succeeded)
            onStateChange?(state)
        }

        func content(
            _ content: CheckoutContentViewController, didRequestDeleteSavedCard id: String,
            completion: @escaping @MainActor (Result<Void, CheckoutError>) -> Void
        ) {
            let delete = onDeleteSavedCard
            Task { @MainActor in
                let result = await delete?(id) ?? .failure(CheckoutErrors.cardDeleteUnsupported())
                completion(result)
            }
        }

        // MARK: - Finish

        /// Resolves the presentation exactly once, optionally dismissing the sheet first.
        private func finish(with outcome: CheckoutOutcome, dismissSheet: Bool) {
            guard !didFinish else { return }
            didFinish = true
            if dismissSheet {
                performDismiss()
            }
            onFinish?(outcome)
        }
    }

    // MARK: - Form-sheet dismissal bridge

    extension PaymentSheetContainerViewController: UIAdaptivePresentationControllerDelegate {
        /// iPad / Mac / visionOS form sheet: the sheet is `isModalInPresentation`, so the system asks
        /// before an outside-tap dismissal. Run the same allowed-or-blocked cancel rule, then always
        /// refuse the system dismissal — an accepted cancel dismisses through `finish`.
        func presentationControllerShouldDismiss(_ presentationController: UIPresentationController) -> Bool {
            requestCancel()
            return false
        }

        /// UIKit reports an outside tap on an `isModalInPresentation` sheet here (not via
        /// `shouldDismiss`); same rule.
        func presentationControllerDidAttemptToDismiss(_ presentationController: UIPresentationController) {
            requestCancel()
        }
    }
#endif
