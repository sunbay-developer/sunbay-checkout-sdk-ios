import Foundation

/// UI-agnostic abstraction for the Apple Pay (wallet) authorization capability.
///
/// ## Layering and the PassKit boundary (see AGENTS.md §2, Task 9 RULING)
/// Core so far does not import any UIKit/PassKit. Although PassKit is not UIKit, to preserve the
/// "Core is independent of UI/platform frameworks" constraint, **only the protocol is placed in Core**
/// (`Sendable`, no PassKit import) for later tasks such as `CheckoutController` to depend on via
/// injection; the **PassKit-backed concrete implementation** `struct WalletAuthorizer`, together with
/// `import PassKit`, lives in the UI layer at
/// `Sources/SunbayCheckout/UI/Wallet/WalletAuthorizerPassKit.swift` (the UI layer may import PassKit;
/// the filename carries the `PassKit` suffix to avoid a basename clash with this Core file).
///
/// Successful wallet authorization ≠ a successful transaction; only a backend-confirmed terminal state counts (product-spec §3.2).
protocol WalletAuthorizing: Sendable {
    /// Whether the device is capable of making Apple Pay payments (device-dependent).
    func canMakePayments() -> Bool

    /// Initiates wallet authorization and returns the encrypted wallet token data (`PKPayment.token.paymentData`).
    ///
    /// - Parameters:
    ///   - amount: The amount of this payment.
    ///   - merchantId: The resolved Apple Pay merchant id (see `resolveMerchantId`).
    /// - Returns: The raw `Data` of the encrypted wallet token (never logged, §5).
    /// - Throws: Throws when authorization is canceled / fails.
    func authorize(amount: Amount, merchantId: String) async throws -> Data
}

/// Resolves the Apple Pay merchant id to use: the host configuration takes precedence over the session-provided one.
///
/// Both merchant-id models go through the same code path; the host's `CheckoutConfiguration.applePayMerchantId`
/// wins if present, otherwise it falls back to the id provided by the session (product-spec §2.1 / §3.2 / §7).
///
/// This function is pure and does not import PassKit, so it is placed in Core alongside the protocol, making it easy to unit-test **without PassKit**.
///
/// - Parameters:
///   - configured: The merchant id configured by the host via `CheckoutConfiguration` (may be nil).
///   - sessionProvided: The merchant id provided by the backend session (may be nil).
/// - Returns: The resolved merchant id; nil when both are nil.
func resolveMerchantId(configured: String?, sessionProvided: String?) -> String? {
    configured ?? sessionProvided
}
