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

        /// Makes `field` part of the sheet's keyboard form navigation:
        ///
        /// - an accessory bar with previous / next arrows and a trailing system "Done" button (the system
        ///   item is localized by UIKit; no SDK string needed). Number-pad style keyboards have no Return
        ///   key, so this bar is how those fields move on or dismiss the keyboard;
        /// - on keyboards that do have a Return key, Return reads "Next" and moves to the next field,
        ///   and reads "Done" (dismissing the keyboard) on the last one.
        ///
        /// The order is the visible text fields in view-hierarchy (= on-screen) order under the field's
        /// enclosing scroll view, so it spans the card form and the address forms.
        static func installFormNavigation(on field: UITextField) {
            let previous = UIBarButtonItem(
                image: UIImage(systemName: "chevron.up"), primaryAction: UIAction { [weak field] _ in
                    guard let field else { return }
                    focus(from: field, offset: -1)
                })
            let next = UIBarButtonItem(
                image: UIImage(systemName: "chevron.down"), primaryAction: UIAction { [weak field] _ in
                    guard let field else { return }
                    focus(from: field, offset: 1)
                })
            let done = UIBarButtonItem(
                systemItem: .done, primaryAction: UIAction { [weak field] _ in
                    field?.resignFirstResponder()
                })
            let bar = UIToolbar()
            bar.sizeToFit()
            bar.items = [
                previous, next, UIBarButtonItem(systemItem: .flexibleSpace), done,
            ]
            field.inputAccessoryView = bar

            field.addAction(
                UIAction { [weak field] _ in
                    guard let field else { return }
                    let fields = navigableFields(containing: field)
                    let index = fields.firstIndex(of: field)
                    previous.isEnabled = (index ?? 0) > 0
                    let hasNext = index.map { $0 + 1 < fields.count } ?? false
                    next.isEnabled = hasNext
                    let wanted: UIReturnKeyType = hasNext ? .next : .done
                    if field.returnKeyType != wanted {
                        field.returnKeyType = wanted
                        field.reloadInputViews()
                    }
                }, for: .editingDidBegin)
            field.addAction(
                UIAction { [weak field] _ in
                    guard let field else { return }
                    if !focus(from: field, offset: 1) { field.resignFirstResponder() }
                }, for: .editingDidEndOnExit)
        }

        /// Moves focus `offset` fields away from `field`. Returns `false` when there is no such field.
        @discardableResult
        static func focus(from field: UITextField, offset: Int) -> Bool {
            let fields = navigableFields(containing: field)
            guard let index = fields.firstIndex(of: field) else { return false }
            let target = index + offset
            guard fields.indices.contains(target) else { return false }
            return fields[target].becomeFirstResponder()
        }

        /// The visible, enabled text fields under `field`'s enclosing scroll view, in on-screen order.
        static func navigableFields(containing field: UITextField) -> [UITextField] {
            var root: UIView = field
            var current: UIView? = field.superview
            while let candidate = current {
                root = candidate
                if candidate is UIScrollView { break }
                current = candidate.superview
            }
            var result: [UITextField] = []
            collect(in: root, into: &result)
            return result
        }

        private static func collect(in view: UIView, into result: inout [UITextField]) {
            if view.isHidden || view.alpha == 0 { return }
            if let field = view as? UITextField {
                if field.isEnabled, field.isUserInteractionEnabled { result.append(field) }
                return
            }
            for subview in view.subviews { collect(in: subview, into: &result) }
        }
    }
#endif
