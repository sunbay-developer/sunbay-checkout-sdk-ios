#if canImport(UIKit)
    import UIKit

    /// Keyboard-dismissal helpers shared by the payment sheet's form pages.
    ///
    /// The card and postal-code fields use number-pad style keyboards, which have no Return key, so
    /// without these affordances the only way to hide the keyboard is dragging the scroll view.
    enum KeyboardDismissal {
        /// Whether a background tap that landed on `view` should dismiss the keyboard.
        ///
        /// Taps on a text input or any control (including anything inside one) are left alone so the
        /// background-tap recognizer never steals focus from the field the user is moving to, nor
        /// interferes with buttons, checkboxes and rows.
        static func shouldHandleTap(on view: UIView?) -> Bool {
            var current = view
            while let candidate = current {
                if candidate is UITextField || candidate is UIControl { return false }
                current = candidate.superview
            }
            return true
        }

        /// Installs a keyboard accessory bar with a trailing system "Done" button on `field`.
        ///
        /// Uses the system Done item so its title is localized by UIKit (no SDK string needed).
        static func installDoneAccessory(on field: UITextField) {
            let bar = UIToolbar()
            bar.sizeToFit()
            bar.items = [
                UIBarButtonItem(barButtonSystemItem: .flexibleSpace, target: nil, action: nil),
                UIBarButtonItem(
                    barButtonSystemItem: .done, target: field,
                    action: #selector(UIResponder.resignFirstResponder)),
            ]
            field.inputAccessoryView = bar
        }
    }
#endif
