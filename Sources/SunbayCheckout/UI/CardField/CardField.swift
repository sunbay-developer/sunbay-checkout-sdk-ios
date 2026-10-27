#if canImport(UIKit)
    import UIKit

    /// A native card input control collecting PAN / expiry / CVV.
    ///
    /// ## Responsibility boundary
    /// `CardField` does only two things:
    /// 1. Holds three `UITextField`s and, at `init`, calls `CardFieldSecurity.apply(...)` to
    ///    apply the unified security configuration (see `CardFieldSecurity` / security-and-pci.md §3.1).
    /// 2. Exposes the assembled `CardInput` via `cardInput`.
    ///
    /// It does **not encrypt, validate business rules, or log / persist** any card data.
    /// Encryption is the sole responsibility of `CardEncryptor` (AGENTS.md §2, Global
    /// Constraints); this control only temporarily carries plaintext within the fields and the
    /// returned `CardInput`, and should discard it as soon as possible after handing it to the
    /// upper layer (Task 12 PaymentSheet). Plaintext is never written to logs / persisted
    /// (§4, sensitive-data boundary).
    ///
    /// ## Validation scope (minimal)
    /// `cardInput` returns non-`nil` only when all four fields are **non-empty** after trimming
    /// leading/trailing whitespace; stricter card-number / expiry validation is left to later
    /// tasks / the backend. The expiry is entered in `MM/YY` or `MM/YYYY` form; here it is split
    /// by `/` into month / year for `CardInput`; if it cannot be split, it is treated as invalid
    /// (returns `nil`).
    ///
    /// iOS-only: the whole thing is gated by `#if canImport(UIKit)` and does not compile under
    /// the macOS host. This task is internal; whether to make it public is decided by Task 12.
    final class CardField: UIView {
        /// Card number (PAN) field.
        let panField = UITextField()
        /// Expiry field (entered in the form `MM/YY`).
        let expiryField = UITextField()
        /// Security code (CVV/CVC) field.
        let cvvField = UITextField()

        /// The container that stacks the three input fields vertically.
        private let stack = UIStackView()

        override init(frame: CGRect) {
            super.init(frame: frame)
            configure()
        }

        required init?(coder: NSCoder) {
            super.init(coder: coder)
            configure()
        }

        /// Applies the security configuration and does a minimal layout.
        private func configure() {
            CardFieldSecurity.apply(toPAN: panField, expiry: expiryField, cvv: cvvField)

            panField.placeholder = "Card number"
            expiryField.placeholder = "MM/YY"
            cvvField.placeholder = "CVV"

            stack.axis = .vertical
            stack.spacing = 8
            stack.translatesAutoresizingMaskIntoConstraints = false
            stack.addArrangedSubview(panField)
            stack.addArrangedSubview(expiryField)
            stack.addArrangedSubview(cvvField)
            addSubview(stack)

            NSLayoutConstraint.activate([
                stack.topAnchor.constraint(equalTo: topAnchor),
                stack.leadingAnchor.constraint(equalTo: leadingAnchor),
                stack.trailingAnchor.constraint(equalTo: trailingAnchor),
                stack.bottomAnchor.constraint(equalTo: bottomAnchor),
            ])
        }

        /// The currently assembled card plaintext input; returns `CardInput` when the fields are complete, otherwise `nil`.
        ///
        /// "Complete" is defined (minimal validation) as: PAN, expiry month, expiry year, and CVV
        /// all non-empty after trimming whitespace. The expiry is split by `/` into "month / year";
        /// returns `nil` when two non-empty segments cannot be parsed out. The returned `CardInput`
        /// carries plaintext; the caller must discard it after use and must not log / persist it.
        var cardInput: CardInput? {
            let pan = (panField.text ?? "").trimmingCharacters(in: .whitespaces)
            let cvv = (cvvField.text ?? "").trimmingCharacters(in: .whitespaces)
            let expiry = (expiryField.text ?? "").trimmingCharacters(in: .whitespaces)

            guard !pan.isEmpty, !cvv.isEmpty, !expiry.isEmpty else { return nil }

            let parts = expiry.split(separator: "/", maxSplits: 1, omittingEmptySubsequences: false)
            guard parts.count == 2 else { return nil }
            let month = parts[0].trimmingCharacters(in: .whitespaces)
            let year = parts[1].trimmingCharacters(in: .whitespaces)
            guard !month.isEmpty, !year.isEmpty else { return nil }

            return CardInput(
                cardNumber: pan,
                expiryMonth: month,
                expiryYear: year,
                cvv: cvv
            )
        }
    }
#endif
