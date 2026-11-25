#if canImport(UIKit)
    import UIKit

    /// An opaque cover that hides the card input fields while their content could be captured.
    ///
    /// The cover is shown when:
    /// - the screen is being recorded, mirrored or sent over AirPlay (`UIScreen.isCaptured`); the keyboard is
    ///   dismissed too, so key highlights cannot reveal digits;
    /// - the app is no longer active (`willResignActive` until `didBecomeActive`), which is the moment the
    ///   system takes the App Switcher snapshot.
    ///
    /// A screenshot taken by the user (side buttons) cannot be blocked with public iOS API, so it is not covered
    /// here. The cover intercepts touches while visible and carries no card data.
    @MainActor
    final class ScreenCaptureShield: UIView {
        private let messageLabel = UILabel()
        private let notificationCenter: NotificationCenter
        private let isScreenCaptured: () -> Bool

        private var isInactive = false
        private var isCaptured = false

        /// Whether the cover is currently shown (read by tests).
        var isCovering: Bool { !isHidden }

        /// Creates a shield.
        ///
        /// - Parameters:
        ///   - backgroundColor: Opaque fill (use the form's background color).
        ///   - textColor: Color of the message.
        ///   - message: Localized text shown while the screen is captured.
        ///   - notificationCenter: Source of the lifecycle and capture notifications (replaceable in tests).
        ///   - isScreenCaptured: Reads the current capture state; defaults to the window's screen.
        init(
            backgroundColor: UIColor, textColor: UIColor, message: String,
            notificationCenter: NotificationCenter = .default,
            isScreenCaptured: (() -> Bool)? = nil
        ) {
            self.notificationCenter = notificationCenter
            self.isScreenCaptured = isScreenCaptured ?? { false }
            super.init(frame: .zero)
            self.backgroundColor = backgroundColor
            isHidden = true
            clipsToBounds = true
            isUserInteractionEnabled = true
            messageLabel.text = message
            messageLabel.textColor = textColor
            messageLabel.font = UIFont.preferredFont(forTextStyle: .footnote)
            messageLabel.textAlignment = .center
            messageLabel.numberOfLines = 0
            messageLabel.translatesAutoresizingMaskIntoConstraints = false
            addSubview(messageLabel)
            NSLayoutConstraint.activate([
                messageLabel.centerYAnchor.constraint(equalTo: centerYAnchor),
                messageLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
                messageLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
            ])
            notificationCenter.addObserver(
                self, selector: #selector(handleResignActive),
                name: UIApplication.willResignActiveNotification, object: nil)
            notificationCenter.addObserver(
                self, selector: #selector(handleBecomeActive),
                name: UIApplication.didBecomeActiveNotification, object: nil)
            notificationCenter.addObserver(
                self, selector: #selector(handleCaptureChanged),
                name: UIScreen.capturedDidChangeNotification, object: nil)
        }

        @available(*, unavailable)
        required init?(coder: NSCoder) {
            fatalError("init(coder:) is not supported")
        }

        deinit {
            notificationCenter.removeObserver(self)
        }

        override func didMoveToWindow() {
            super.didMoveToWindow()
            refresh()
        }

        /// Re-reads the capture state and updates the cover.
        func refresh() {
            isCaptured = window?.screen.isCaptured ?? isScreenCaptured()
            apply()
        }

        @objc private func handleResignActive() {
            isInactive = true
            apply()
        }

        @objc private func handleBecomeActive() {
            isInactive = false
            refresh()
        }

        @objc private func handleCaptureChanged() {
            refresh()
        }

        private func apply() {
            let shouldCover = isInactive || isCaptured
            messageLabel.isHidden = !isCaptured
            if shouldCover, isCaptured, superview != nil {
                // Hide the keyboard so key highlights cannot reveal digits in a recording.
                superview?.window?.endEditing(true)
            }
            isHidden = !shouldCover
        }
    }
#endif
