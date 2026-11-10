import Foundation

/// Decides whether Apple Pay may be offered, and which backend parameters (by name) make it unusable.
enum ApplePayAvailability {
    struct Result: Equatable {
        let available: Bool
        /// Names of the missing / unusable required parameters (never values); empty when none or when Apple Pay is not offered.
        let missing: [String]
    }

    /// Available iff the session has an `APPLE_PAY` entry, the host filter does not hide it, the device can pay,
    /// a merchant id exists and no required parameter is missing.
    static func evaluate(
        session: CheckoutSession,
        hiddenByFilter: Bool,
        authorizer: any WalletAuthorizing,
        merchantId: String?
    ) -> Result {
        guard session.methods.contains(.applePay), !hiddenByFilter else {
            return Result(available: false, missing: [])
        }
        let missing = authorizer.missingParameters(for: session.applePayParams)
        let available = authorizer.canMakePayments() && merchantId != nil && missing.isEmpty
        return Result(available: available, missing: missing)
    }
}
