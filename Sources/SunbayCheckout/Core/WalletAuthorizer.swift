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

    /// The names of the required Apple Pay parameters that are missing or unusable (empty = usable).
    ///
    /// Names only, never values. Apple Pay must be hidden while this is non-empty.
    func missingParameters(for params: ApplePayParams?) -> [String]

    /// Runs one Apple Pay authorization, confirming each authorized token with the backend
    /// **while the system sheet is still open**, and returns the final outcome once it closes.
    ///
    /// Flow (Apple's recommended order): the user authorizes → the encrypted token
    /// (`PKPayment.token.paymentData`) is passed to `confirm` → the backend outcome decides the status
    /// the system sheet shows (`succeeded` / `pending` / `unknown` → success, so the sheet closes and
    /// no second charge is attempted; `failed` → failure, the user may retry with another card or
    /// cancel inside the sheet, which calls `confirm` again with a new token). The sheet never shows a
    /// checkmark before the backend has answered.
    ///
    /// - Parameters:
    ///   - amount: The amount of this payment.
    ///   - merchantId: The resolved Apple Pay merchant id (see `resolveMerchantId`).
    ///   - merchantName: The merchant name shown as the payment summary label ("Total" when blank).
    ///   - params: The backend Apple Pay parameters (networks, capabilities, country).
    ///   - contacts: Which billing / shipping contacts the sheet must request.
    ///   - confirm: Submits one authorization (token and returned contacts) to the backend and returns its
    ///     outcome. The authorization is used only here and is never logged (§5).
    /// - Returns: The outcome of the last confirm made in this authorization (if the system sheet
    ///   timed out while a confirm was in flight, that confirm's outcome is awaited first).
    /// - Throws: Only when the sheet closed **without any token** being authorized (user cancel →
    ///   `CheckoutError` code `WALLET_CANCELED`; present/authorization failure → other codes). Once a
    ///   token was submitted it never throws: the result is the backend outcome.
    func authorize(
        amount: Amount,
        merchantId: String,
        merchantName: String,
        params: ApplePayParams?,
        contacts: WalletContactRequest,
        confirm: @escaping @Sendable (WalletAuthorization) async -> CheckoutOutcome
    ) async throws -> CheckoutOutcome
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
