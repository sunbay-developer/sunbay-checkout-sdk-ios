#if canImport(UIKit)
    import UIKit

    /// A transient message bubble shown over the content (for short, non-blocking feedback such as a
    /// failed saved-card delete). It fades in, stays for a few seconds, then fades out and removes itself.
    ///
    /// Colors invert the theme (text color as the bubble, background color as the text) so it stands out
    /// in both light and dark mode. The bubble does not intercept touches.
    ///
    /// iOS-only: gated by `#if canImport(UIKit)`; does not compile under the macOS host (`swift test`).
    final class ToastView: UIView {
        private let label = UILabel()
        private var dismissWork: DispatchWorkItem?

        /// - Parameters:
        ///   - appearance: The resolved appearance (colors, font, corner radius).
        ///   - message: The localized message.
        init(appearance: ResolvedAppearance, message: String) {
            super.init(frame: .zero)
            isUserInteractionEnabled = false
            backgroundColor = appearance.text.withAlphaComponent(0.92)
            layer.cornerRadius = max(appearance.cornerRadius, 12)
            alpha = 0

            label.text = message
            label.font = UIFont.preferredFont(forTextStyle: .subheadline)
            label.adjustsFontForContentSizeCategory = true
            label.textColor = appearance.background
            label.numberOfLines = 0
            label.textAlignment = .center
            label.translatesAutoresizingMaskIntoConstraints = false
            addSubview(label)
            NSLayoutConstraint.activate([
                label.topAnchor.constraint(equalTo: topAnchor, constant: 10),
                label.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -10),
                label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 16),
                label.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -16),
            ])

            isAccessibilityElement = true
            accessibilityLabel = message
            accessibilityTraits = .staticText
        }

        @available(*, unavailable)
        required init?(coder: NSCoder) {
            fatalError("init(coder:) is not supported")
        }

        /// Shows `message` as a bubble centered horizontally in `container`, `bottomOffset` points above
        /// the anchor's top edge. Replaces any toast already on screen.
        ///
        /// - Parameters:
        ///   - container: The view to host the toast.
        ///   - anchor: The view whose top edge the bubble sits above.
        ///   - duration: Seconds on screen before fading out.
        @discardableResult
        static func show(
            _ message: String, appearance: ResolvedAppearance, in container: UIView, above anchor: UIView,
            duration: TimeInterval = 2.5
        ) -> ToastView {
            container.subviews.compactMap { $0 as? ToastView }.forEach { $0.removeFromSuperview() }
            let toast = ToastView(appearance: appearance, message: message)
            toast.translatesAutoresizingMaskIntoConstraints = false
            container.addSubview(toast)
            NSLayoutConstraint.activate([
                toast.centerXAnchor.constraint(equalTo: container.centerXAnchor),
                toast.bottomAnchor.constraint(equalTo: anchor.topAnchor, constant: -12),
                toast.leadingAnchor.constraint(greaterThanOrEqualTo: container.leadingAnchor, constant: 24),
                toast.trailingAnchor.constraint(lessThanOrEqualTo: container.trailingAnchor, constant: -24),
            ])
            UIView.animate(withDuration: 0.2) { toast.alpha = 1 }
            UIAccessibility.post(notification: .announcement, argument: message)
            let work = DispatchWorkItem { [weak toast] in
                guard let toast else { return }
                UIView.animate(withDuration: 0.25, animations: { toast.alpha = 0 }) { _ in
                    toast.removeFromSuperview()
                }
            }
            toast.dismissWork = work
            DispatchQueue.main.asyncAfter(deadline: .now() + duration, execute: work)
            return toast
        }

        deinit { dismissWork?.cancel() }
    }
#endif
