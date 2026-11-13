#if canImport(UIKit)
    import UIKit

    /// What the host may show about the payment option currently selected in a `CardElement` (display only).
    ///
    /// It carries a label, a brand image and a type; never card numbers, tokens, secrets or ciphertext.
    public struct PaymentOptionDisplayData: @unchecked Sendable {
        /// Localized text such as "Visa ····4242" (saved card) or the brand name (typed new card).
        public let label: String
        /// The brand image, when one is available. It may be `nil` until the logo has loaded, and the host
        /// is not notified when it arrives: read `CheckoutElements.paymentOption` again to pick it up.
        public let image: UIImage?
        /// The payment method type, e.g. `"CARD"`.
        public let paymentMethodType: String

        init(label: String, image: UIImage?, paymentMethodType: String) {
            self.label = label
            self.image = image
            self.paymentMethodType = paymentMethodType
        }
    }
#endif
