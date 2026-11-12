import Foundation

/// Hands user actions from a UI shell to the loop that executes them.
///
/// ## No lost user action
/// A user action can arrive while nobody is suspended in `next()` (for example a Pay tap in the unlock
/// window after a `.failed`, while the loop is still reloading). It is buffered instead of dropped and
/// delivered to the next `next()`. At most ONE action is buffered: the first wins, except that a
/// `.cancel` always replaces the buffered action. Once `cancel()` was called, `next()` returns `.cancel`
/// every time (a cancel beats anything buffered or posted later).
///
/// `@MainActor`: the shells (UIKit) call it from the main actor. Core stays UI-agnostic: this type uses
/// no UIKit.
@MainActor
final class UserActionChannel {
    private var buffered: CheckoutUserAction?
    private var continuation: CheckedContinuation<CheckoutUserAction, Never>?

    /// Whether `cancel()` was called (the user closed the presentation).
    private(set) var wasCanceled = false

    init() {}

    /// Suspends until the next user action (or returns a buffered one / `.cancel` right away).
    func next() async -> CheckoutUserAction {
        await withCheckedContinuation { continuation in
            if wasCanceled {
                buffered = nil
                continuation.resume(returning: .cancel)
                return
            }
            if let action = buffered {
                buffered = nil
                continuation.resume(returning: action)
                return
            }
            self.continuation = continuation
        }
    }

    /// Delivers an action to the waiter, or buffers it when nobody is waiting.
    func post(_ action: CheckoutUserAction) {
        guard let continuation else {
            if case .cancel = action {
                buffered = action
            } else if buffered == nil {
                buffered = action
            }
            return
        }
        self.continuation = nil
        continuation.resume(returning: action)
    }

    /// Records that the user canceled and wakes the waiter (or buffers the cancel).
    func cancel() {
        wasCanceled = true
        post(.cancel)
    }
}
