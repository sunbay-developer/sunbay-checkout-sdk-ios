#if canImport(UIKit)
    import UIKit

    /// The **unified security configuration** for the card input controls (PAN / expiry / CVV), centralized here in one place.
    ///
    /// Implements the per-field spec in security-and-pci.md §3 item 2 and §3.1, and product-spec §5.3.1:
    /// - All three fields uniformly disable autocorrection / spell checking / the smart family
    ///   (dashes, quotes, insert-delete), and use `.asciiCapableNumberPad`, to prevent plaintext
    ///   from entering the keyboard's self-learning dictionary / QuickType cache.
    /// - PAN: `textContentType = .creditCardNumber`, enabling system card scanning / autofill
    ///   (an Apple-sanctioned secure channel).
    /// - CVV: `textContentType = nil`, **never entering autofill / system memory**; additionally
    ///   enables `isSecureTextEntry` (anti shoulder-surfing; the spec allows CVV secure entry).
    /// - Expiry: number pad + autocorrection off, no special contentType.
    ///
    /// This type **does not touch card plaintext**; it only configures the `UITextField`'s
    /// keyboard / autofill / cache behavior. Plaintext only ever flows within the field and
    /// the assembled `CardInput` (see §4, sensitive-data boundary).
    ///
    /// iOS-only: `UITextField` belongs to UIKit, so the whole thing is gated by
    /// `#if canImport(UIKit)` and does not compile under the macOS host (`swift test`).
    /// On-device verification is covered by the example app (Task 13).
    enum CardFieldSecurity {
        /// Applies the unified security configuration to the three card fields.
        ///
        /// - Parameters:
        ///   - pan: Card number field (PAN).
        ///   - expiry: Expiry date field.
        ///   - cvv: Security code field (CVV/CVC).
        static func apply(toPAN pan: UITextField, expiry: UITextField, cvv: UITextField) {
            // The common "disable keyboard self-learning / suggestions / smart" baseline shared by the three fields.
            for field in [pan, expiry, cvv] {
                field.autocorrectionType = .no
                field.spellCheckingType = .no
                field.smartDashesType = .no
                field.smartQuotesType = .no
                field.smartInsertDeleteType = .no
                field.keyboardType = .asciiCapableNumberPad
            }

            // PAN: allow system card scanning / autofill (an Apple-sanctioned secure channel).
            pan.textContentType = .creditCardNumber

            // CVV: never remembered / autofilled by the system; and enable secure entry against shoulder-surfing.
            cvv.textContentType = nil
            cvv.isSecureTextEntry = true

            // Expiry: number pad only + autocorrection off (already covered by the baseline), no special contentType.
            expiry.textContentType = nil
        }
    }
#endif
