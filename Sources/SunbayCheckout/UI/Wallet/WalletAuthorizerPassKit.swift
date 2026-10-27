import Foundation
import PassKit

/// The PassKit-backed concrete implementation of `WalletAuthorizing`.
///
/// ## Why it lives in the UI layer rather than Core
/// Core is constrained to "not import UIKit/PassKit" (AGENTS.md §2, Task 9 RULING). The
/// protocol `WalletAuthorizing` and the pure function `resolveMerchantId` stay in Core
/// (`Sendable`, no PassKit), while `import PassKit` together with this concrete type is
/// centralized in this UI-layer file, isolating the platform-framework dependency. The file
/// is named `WalletAuthorizerPassKit.swift` (rather than `WalletAuthorizer.swift`) to avoid a
/// conflict with Core's file of the same name in the build system (the basename must be unique).
///
/// ## Unit-test scope and the Task 14 probe
/// The full `PKPaymentAuthorizationController` delegate flow requires a real device + an Apple
/// Pay certificate/entitlement and cannot be verified end to end in a pure unit-test
/// environment. So this type stays "thin": it only verifies that it can be constructed and that
/// `canMakePayments()` is callable; the real token flow is covered by the Task 14 on-device
/// probe. Authorization success ≠ transaction success (product-spec §3.2).
///
/// ## Platform and Swift 6 Sendable simplification notes
/// - The SDK targets iOS, but `swift test` builds on the macOS host.
///   `PKPaymentAuthorizationControllerDelegate` requires an additional
///   `presentationWindow(for:)` on macOS, whose presentation path differs from iOS; so the
///   full `present + delegate` authorization flow is gated by `#if os(iOS)`, and on macOS
///   `authorize` directly throws "platform not supported". Both `canMakePayments()` and
///   `makeRequest()` compile on both platforms and are covered by unit tests as
///   "callable / constructible".
/// - `PKPayment` / `PKPaymentToken` are not `Sendable`. To keep them from crossing concurrency
///   boundaries, the delegate extracts `payment.token.paymentData` as `Data` (`Sendable`) while
///   inside `@MainActor`, and only the `Data` (or error) is returned via the continuation. The
///   returned token `Data` is never logged (§5).
struct WalletAuthorizer: WalletAuthorizing {
    /// Whether the device has Apple Pay payment capability.
    ///
    /// Directly delegates to `PKPaymentAuthorizationController.canMakePayments()` (device-related).
    func canMakePayments() -> Bool {
        PKPaymentAuthorizationController.canMakePayments()
    }

    /// Starts Apple Pay authorization and returns the encrypted wallet token data.
    ///
    /// Constructs a `PKPaymentRequest` from the given `merchantId` + `amount`, presents the
    /// system authorization sheet, and after authorization completes returns
    /// `PKPayment.token.paymentData`.
    ///
    /// - Parameters:
    ///   - amount: The amount for this payment (in the smallest currency unit).
    ///   - merchantId: The resolved Apple Pay merchant id.
    /// - Returns: The raw `Data` of the encrypted wallet token.
    /// - Throws: Throws `CheckoutError` on user cancel / system authorization failure / a non-iOS platform.
    func authorize(amount: Amount, merchantId: String) async throws -> Data {
        let request = Self.makeRequest(amount: amount, merchantId: merchantId)
        return try await Self.runAuthorization(request)
    }

    // MARK: - Construction (compiles on both platforms)

    /// Constructs a `PKPaymentRequest` from merchantId + amount.
    ///
    /// The amount is converted from the smallest currency unit (minor units) into the decimal
    /// display amount; network/capability and other details await backend confirmation (aligned
    /// with the Task 14 on-device probe).
    static func makeRequest(amount: Amount, merchantId: String) -> PKPaymentRequest {
        let request = PKPaymentRequest()
        request.merchantIdentifier = merchantId
        request.currencyCode = amount.currencyCode
        request.countryCode = "US"
        request.supportedNetworks = [.visa, .masterCard, .amex]
        request.merchantCapabilities = [.threeDSecure]

        let decimal = Decimal(amount.minorUnits) / Decimal(100)
        request.paymentSummaryItems = [
            PKPaymentSummaryItem(
                label: "Total",
                amount: NSDecimalNumber(decimal: decimal)
            )
        ]
        return request
    }

    // MARK: - Authorization run (iOS-specific delegate flow)

    #if os(iOS)
    private static func runAuthorization(_ request: PKPaymentRequest) async throws -> Data {
        try await withCheckedThrowingContinuation { continuation in
            Task { @MainActor in
                let controller = PKPaymentAuthorizationController(paymentRequest: request)
                let delegate = AuthorizationDelegate(continuation: continuation)
                controller.delegate = delegate
                // The delegate must stay alive until authorization completes; retain it until the flow ends.
                delegate.retainController = controller
                controller.present { presented in
                    if !presented {
                        delegate.finish(
                            throwing: CheckoutError(
                                code: "WALLET_PRESENT_FAILED",
                                message: "Failed to present Apple Pay.",
                                category: .runtime,
                                traceId: nil
                            )
                        )
                    }
                }
            }
        }
    }

    /// The `PKPaymentAuthorizationController` delegate.
    ///
    /// Within `@MainActor`, it narrows the non-`Sendable` `PKPayment` down to `Data` before
    /// returning it via the continuation, avoiding non-`Sendable` types crossing the concurrency
    /// boundary. Ensures the continuation is resumed exactly once.
    @MainActor
    private final class AuthorizationDelegate: NSObject, PKPaymentAuthorizationControllerDelegate {
        private var continuation: CheckedContinuation<Data, Error>?
        /// Holds the controller until the authorization flow ends, avoiding premature release.
        var retainController: PKPaymentAuthorizationController?

        init(continuation: CheckedContinuation<Data, Error>) {
            self.continuation = continuation
        }

        func finish(throwing error: Error) {
            continuation?.resume(throwing: error)
            continuation = nil
        }

        private func finish(returning data: Data) {
            continuation?.resume(returning: data)
            continuation = nil
        }

        func paymentAuthorizationController(
            _ controller: PKPaymentAuthorizationController,
            didAuthorizePayment payment: PKPayment,
            handler completion: @escaping (PKPaymentAuthorizationResult) -> Void
        ) {
            // Extract only the token data (Sendable); do not log any sensitive content (§5).
            let tokenData = payment.token.paymentData
            completion(PKPaymentAuthorizationResult(status: .success, errors: nil))
            finish(returning: tokenData)
        }

        func paymentAuthorizationControllerDidFinish(
            _ controller: PKPaymentAuthorizationController
        ) {
            controller.dismiss(completion: nil)
            // Finishing without authorization → treated as a user cancel; a no-op if already resumed.
            finish(
                throwing: CheckoutError(
                    code: "WALLET_CANCELED",
                    message: "Apple Pay authorization was canceled.",
                    category: .runtime,
                    traceId: nil
                )
            )
            retainController = nil
        }
    }
    #else
    /// A non-iOS platform (such as the macOS unit-test host) has no available authorization presentation path; the on-device flow is covered by Task 14.
    private static func runAuthorization(_ request: PKPaymentRequest) async throws -> Data {
        throw CheckoutError(
            code: "WALLET_UNSUPPORTED_PLATFORM",
            message: "Apple Pay authorization is only available on iOS.",
            category: .runtime,
            traceId: nil
        )
    }
    #endif
}
