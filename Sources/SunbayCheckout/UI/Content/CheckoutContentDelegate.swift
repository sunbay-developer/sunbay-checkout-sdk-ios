#if canImport(UIKit)
    import CoreGraphics
    import UIKit

    /// The outward-facing boundary of the content layer (spec §3.3).
    ///
    /// `CheckoutContentViewController` is host-agnostic: it composes the card form, saved-card list,
    /// address forms, express row, and confirm button, owns the visible `CheckoutStateMachine`, and
    /// talks to the outside world **only** through this delegate. It never references the container
    /// (`PaymentSheetContainerViewController`, Task 9) or `CheckoutController` directly — that is what
    /// lets the same content VC drop into the future L2 embedded container with zero rework.
    ///
    /// The container implements this delegate: it bridges a requested `PaymentSheet.UserAction` into
    /// the existing `PaymentSheet.runCheckout` seam, drives `CheckoutController`, and feeds the
    /// resulting `CheckoutOutcome` back via `applyOutcome(_:)`. `didChangeProcessing` lets it block
    /// dismissal, and `didChangeState` is mapped to the public `CheckoutPresentationState` surfaced on
    /// `PaymentSheet.onStateChange`. `didUpdateContentHeight` drives the custom bottom sheet's height and is
    /// the zero-rework seam for the L2 embedded height animation.
    ///
    /// `@MainActor`: every callback is invoked on the main actor (UIKit affinity).
    ///
    /// iOS-only: gated by `#if canImport(UIKit)`; does not compile under the macOS host (`swift test`).
    @MainActor
    protocol CheckoutContentDelegate: AnyObject {
        /// The user committed a confirm intent (new card / saved card / wallet token obtained).
        ///
        /// The delegate forwards this `PaymentSheet.UserAction` into `runCheckout`, which drives the
        /// controller and eventually calls back `applyOutcome(_:)`.
        ///
        /// - Parameters:
        ///   - content: The reporting content view controller.
        ///   - action: The requested confirm action (reuses the existing `PaymentSheet.UserAction`).
        func content(_ content: CheckoutContentViewController, didRequest action: PaymentSheet.UserAction)

        /// The user asked to cancel (tapped close / back on the root screen).
        ///
        /// - Parameter content: The reporting content view controller.
        func contentDidRequestCancel(_ content: CheckoutContentViewController)

        /// The flow reached a terminal outcome and the content finished (after the success animation
        /// for `.succeeded`).
        ///
        /// - Parameters:
        ///   - content: The reporting content view controller.
        ///   - outcome: The terminal outcome to return to the host.
        func content(_ content: CheckoutContentViewController, didFinishWith outcome: CheckoutOutcome)

        /// The processing state changed (confirm in flight ↔ editable).
        ///
        /// The container uses this to block / allow interactive dismissal (`isModalInPresentation`).
        ///
        /// - Parameters:
        ///   - content: The reporting content view controller.
        ///   - isProcessing: `true` when a confirm is in flight; `false` when editable again.
        func content(_ content: CheckoutContentViewController, didChangeProcessing isProcessing: Bool)

        /// The preferred total content height changed.
        ///
        /// The bottom sheet uses this as its explicit height; the future embedded container
        /// animates its own height from it.
        ///
        /// - Parameters:
        ///   - content: The reporting content view controller.
        ///   - height: The new preferred content height, in points.
        func content(_ content: CheckoutContentViewController, didUpdateContentHeight height: CGFloat)

        /// The coarse-grained presentation state changed (→ public `PaymentSheet.onStateChange`).
        ///
        /// - Parameters:
        ///   - content: The reporting content view controller.
        ///   - state: The new public presentation state.
        func content(_ content: CheckoutContentViewController, didChangeState state: CheckoutPresentationState)
    }
#endif
