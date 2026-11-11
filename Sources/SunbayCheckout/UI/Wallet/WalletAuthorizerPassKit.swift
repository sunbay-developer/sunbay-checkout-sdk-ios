import Contacts
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
///   inside `@MainActor`, and only the `Data` is handed to `confirm`; only the resulting
///   `CheckoutOutcome` (or an error) is returned via the continuation. The token `Data` is never
///   logged (§5).
struct WalletAuthorizer: WalletAuthorizing {
    /// Whether the device has Apple Pay payment capability.
    ///
    /// Directly delegates to `PKPaymentAuthorizationController.canMakePayments()` (device-related).
    func canMakePayments() -> Bool {
        PKPaymentAuthorizationController.canMakePayments()
    }

    /// Runs one Apple Pay authorization, confirming each token with the backend while the system
    /// sheet is still open (see `WalletAuthorizing.authorize(amount:merchantId:confirm:)`).
    ///
    /// - Parameters:
    ///   - amount: The amount for this payment (in the smallest currency unit).
    ///   - merchantId: The resolved Apple Pay merchant id.
    ///   - confirm: Submits one token to the backend and returns its outcome.
    /// - Returns: The outcome of the last confirm made in this authorization.
    /// - Throws: `CheckoutError` only when no token was authorized (cancel / present failure / a
    ///   non-iOS platform).
    func authorize(
        amount: Amount,
        merchantId: String,
        merchantName: String,
        params: ApplePayParams?,
        contacts: WalletContactRequest,
        confirm: @escaping @Sendable (WalletAuthorization) async -> CheckoutOutcome
    ) async throws -> CheckoutOutcome {
        guard missingParameters(for: params).isEmpty, let params else {
            throw CheckoutError(
                code: "WALLET_PARAMS_INVALID",
                message: "Apple Pay parameters are missing or unusable.",
                category: .configuration,
                traceId: nil)
        }
        let request = Self.makeRequest(
            amount: amount, merchantId: merchantId, merchantName: merchantName, params: params, contacts: contacts)
        return try await Self.runAuthorization(request, confirm: confirm)
    }

    /// `supportedNetworks` / `merchantCapabilities` that map to nothing are reported by name (never values).
    func missingParameters(for params: ApplePayParams?) -> [String] {
        var missing: [String] = []
        if Self.networks(from: params?.supportedNetworks ?? []).isEmpty { missing.append("supportedNetworks") }
        if Self.capabilities(from: params?.merchantCapabilities ?? []).isEmpty { missing.append("merchantCapabilities") }
        return missing
    }

    /// Maps a backend outcome to the status shown in the Apple Pay sheet (pure; both platforms).
    ///
    /// - `succeeded` → `.success`.
    /// - `pending` / `unknown` → `.success`: the payment may already be in flight, so the sheet must
    ///   close instead of inviting a retry that could double-charge. The host reconciles the final
    ///   state via `retrievePayment()` / webhook; the SDK UI shows the "confirming" notice.
    /// - `failed` / `canceled` → `.failure`: nothing was charged; the sheet lets the user retry with
    ///   another card or cancel.
    static func authorizationStatus(for outcome: CheckoutOutcome) -> PKPaymentAuthorizationStatus {
        switch outcome {
        case .succeeded, .pending, .unknown:
            return .success
        case .failed, .canceled:
            return .failure
        }
    }

    // MARK: - Construction (compiles on both platforms)

    /// Constructs a `PKPaymentRequest` from the merchant id, amount, backend parameters and requested contacts.
    ///
    /// The amount is converted from minor units into the decimal display amount; the summary label is the
    /// merchant name ("Total" when blank); the country code is the backend value uppercased (`US` when blank).
    static func makeRequest(
        amount: Amount,
        merchantId: String,
        merchantName: String,
        params: ApplePayParams?,
        contacts: WalletContactRequest
    ) -> PKPaymentRequest {
        let request = PKPaymentRequest()
        request.merchantIdentifier = merchantId
        request.currencyCode = amount.currencyCode
        let country = params?.countryCode?.trimmingCharacters(in: .whitespacesAndNewlines).uppercased() ?? ""
        request.countryCode = country.isEmpty ? "US" : country
        request.supportedNetworks = networks(from: params?.supportedNetworks ?? [])
        request.merchantCapabilities = capabilities(from: params?.merchantCapabilities ?? [])
        if contacts.billing { request.requiredBillingContactFields = [.postalAddress, .name] }
        if contacts.shipping { request.requiredShippingContactFields = [.postalAddress, .name, .phoneNumber] }

        let label = merchantName.trimmingCharacters(in: .whitespacesAndNewlines)
        let decimal = Decimal(amount.minorUnits) / Decimal(100)
        request.paymentSummaryItems = [
            PKPaymentSummaryItem(
                label: label.isEmpty ? "Total" : label,
                amount: NSDecimalNumber(decimal: decimal)
            )
        ]
        return request
    }

    // MARK: - Mapping (pure)

    private static let networkTable: [String: PKPaymentNetwork] = [
        "amex": .amex, "chinaunionpay": .chinaUnionPay, "discover": .discover, "jcb": .JCB,
        "mastercard": .masterCard, "visa": .visa, "maestro": .maestro, "electron": .electron,
        "vpay": .vPay, "interac": .interac, "eftpos": .eftpos, "cartesbancaires": .cartesBancaires,
        "privatelabel": .privateLabel, "quicpay": .quicPay, "idcredit": .idCredit, "suica": .suica,
        "mada": .mada, "elo": .elo, "girocard": .girocard,
    ]

    /// Maps backend network names to PassKit networks (case-insensitive); unknown names and duplicates are dropped, order is kept.
    static func networks(from names: [String]) -> [PKPaymentNetwork] {
        var seen = Set<PKPaymentNetwork>()
        var out: [PKPaymentNetwork] = []
        for name in names {
            let key = name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            if let network = networkTable[key], seen.insert(network).inserted { out.append(network) }
        }
        return out
    }

    /// Maps backend capability names to a PassKit capability set; unknown names are dropped.
    static func capabilities(from names: [String]) -> PKMerchantCapability {
        var out: PKMerchantCapability = []
        for name in names {
            switch name.trimmingCharacters(in: .whitespacesAndNewlines) {
            case "supports3DS": out.insert(.threeDSecure)
            case "supportsEMV": out.insert(.emv)
            case "supportsCredit": out.insert(.credit)
            case "supportsDebit": out.insert(.debit)
            default: break
            }
        }
        return out
    }

    /// Maps a returned `PKContact` to an address; nil when the contact has no non-blank field. Values are never logged.
    static func address(from contact: PKContact?) -> AddressInput? {
        guard let contact else { return nil }
        let lines = (contact.postalAddress?.street ?? "")
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        let input = AddressInput(
            country: contact.postalAddress?.isoCountryCode.uppercased(),
            line1: lines.first,
            line2: lines.count > 1 ? lines.dropFirst().joined(separator: ", ") : nil,
            city: contact.postalAddress?.city,
            state: contact.postalAddress?.state,
            postalCode: contact.postalAddress?.postalCode,
            firstName: contact.name?.givenName,
            lastName: contact.name?.familyName,
            phone: contact.phoneNumber?.stringValue)
        return AddressRules.sanitize(input)
    }

    /// The contact's email, trimmed; nil when absent or blank.
    static func email(from contact: PKContact?) -> String? {
        guard let value = contact?.emailAddress?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty
        else { return nil }
        return value
    }

    // MARK: - Authorization run (iOS-specific delegate flow)

    #if os(iOS)
    private static func runAuthorization(
        _ request: PKPaymentRequest,
        confirm: @escaping @Sendable (WalletAuthorization) async -> CheckoutOutcome
    ) async throws -> CheckoutOutcome {
        try await withCheckedThrowingContinuation { continuation in
            Task { @MainActor in
                let controller = PKPaymentAuthorizationController(paymentRequest: request)
                let delegate = AuthorizationDelegate(
                    continuation: continuation, confirm: confirm, merchantIdentifier: request.merchantIdentifier)
                controller.delegate = delegate
                // `PKPaymentAuthorizationController.delegate` is WEAK, and this Task ends as soon as
                // `present()` returns. Without an owner the delegate would be freed, `DidFinish` would
                // never fire, `dismiss` would never run, and the system sheet could not be closed. The
                // delegate therefore retains itself (and the controller) until the flow ends.
                delegate.retainController = controller
                delegate.retainSelf()
                // Use the async `present()` variant: we are already inside a `@MainActor` Task,
                // so this avoids the completion-handler form and keeps `finish(throwing:)` on the
                // main actor (both the "async alternative" and "main actor-isolated call" warnings).
                let presented = await controller.present()
                if !presented {
                    delegate.finish(
                        throwing: CheckoutError(
                            code: "WALLET_PRESENT_FAILED",
                            message: "Failed to present Apple Pay.",
                            category: .runtime,
                            traceId: nil
                        )
                    )
                    delegate.release()
                }
            }
        }
    }

    /// The `PKPaymentAuthorizationController` delegate.
    ///
    /// ## Confirm while the sheet is open (Apple's recommended order)
    /// `didAuthorizePayment` narrows the non-`Sendable` `PKPayment` down to the token `Data`, submits
    /// it through `confirm`, and only answers PassKit's `completion` once the backend outcome is known
    /// (mapped by `WalletAuthorizer.authorizationStatus(for:)`). A `.failure` keeps the sheet open, so
    /// the user may authorize again (another `didAuthorizePayment` → another confirm).
    ///
    /// ## Resolution
    /// The continuation is resumed exactly once, in `DidFinish`: with the last confirm's outcome when
    /// at least one token was submitted (awaiting a confirm still in flight, e.g. when PassKit timed the
    /// sheet out), otherwise with `WALLET_CANCELED`.
    @MainActor
    private final class AuthorizationDelegate: NSObject, PKPaymentAuthorizationControllerDelegate {
        private var continuation: CheckedContinuation<CheckoutOutcome, Error>?
        private let confirm: @Sendable (WalletAuthorization) async -> CheckoutOutcome
        /// The merchant id of the presented request; attached to every authorization.
        private let merchantIdentifier: String
        /// Holds the controller until the authorization flow ends, avoiding premature release.
        var retainController: PKPaymentAuthorizationController?
        /// Self-retention: PassKit holds the delegate weakly, so the delegate keeps itself alive
        /// until `paymentAuthorizationControllerDidFinish` (or a failed present) releases it.
        private var selfRetain: AuthorizationDelegate?
        /// The outcome of the most recent completed confirm (nil = no token submitted yet).
        private var lastOutcome: CheckoutOutcome?
        /// The confirm currently in flight (nil when none).
        private var inFlightConfirm: Task<CheckoutOutcome, Never>?

        init(
            continuation: CheckedContinuation<CheckoutOutcome, Error>,
            confirm: @escaping @Sendable (WalletAuthorization) async -> CheckoutOutcome,
            merchantIdentifier: String
        ) {
            self.continuation = continuation
            self.confirm = confirm
            self.merchantIdentifier = merchantIdentifier
        }

        /// Keeps this delegate alive for the duration of the PassKit flow.
        func retainSelf() {
            selfRetain = self
        }

        /// Ends the flow: drops the controller and the self-retention.
        func release() {
            retainController = nil
            selfRetain = nil
        }

        func finish(throwing error: Error) {
            continuation?.resume(throwing: error)
            continuation = nil
        }

        private func finish(returning outcome: CheckoutOutcome) {
            continuation?.resume(returning: outcome)
            continuation = nil
        }

        func paymentAuthorizationController(
            _ controller: PKPaymentAuthorizationController,
            didAuthorizePayment payment: PKPayment,
            handler completion: @escaping (PKPaymentAuthorizationResult) -> Void
        ) {
            // Narrow the non-Sendable PKPayment to a Sendable authorization; log nothing (§5).
            let authorization = WalletAuthorization(
                token: payment.token.paymentData,
                billing: WalletAuthorizer.address(from: payment.billingContact),
                shipping: WalletAuthorizer.address(from: payment.shippingContact),
                email: WalletAuthorizer.email(from: payment.shippingContact)
                    ?? WalletAuthorizer.email(from: payment.billingContact),
                merchantIdentifier: merchantIdentifier)
            let confirm = confirm
            let task = Task { await confirm(authorization) }
            inFlightConfirm = task
            Task { @MainActor in
                let outcome = await task.value
                self.lastOutcome = outcome
                if self.inFlightConfirm == task { self.inFlightConfirm = nil }
                // Answer the sheet only now: it never shows a checkmark before the backend has spoken.
                completion(
                    PKPaymentAuthorizationResult(
                        status: WalletAuthorizer.authorizationStatus(for: outcome),
                        errors: nil
                    )
                )
            }
        }

        func paymentAuthorizationControllerDidFinish(
            _ controller: PKPaymentAuthorizationController
        ) {
            controller.dismiss(completion: nil)
            let pending = inFlightConfirm
            Task { @MainActor in
                // PassKit may finish (e.g. timeout) while a confirm is still in flight: the payment
                // may be submitted, so wait for its outcome instead of reporting a cancel.
                if let pending {
                    self.lastOutcome = await pending.value
                }
                if let outcome = self.lastOutcome {
                    self.finish(returning: outcome)
                } else {
                    // Finished without any authorized token → a user cancel.
                    self.finish(
                        throwing: CheckoutError(
                            code: "WALLET_CANCELED",
                            message: "Apple Pay authorization was canceled.",
                            category: .runtime,
                            traceId: nil
                        )
                    )
                }
                self.release()
            }
        }
    }
    #else
    /// A non-iOS platform (such as the macOS unit-test host) has no available authorization presentation path; the on-device flow is covered by Task 14.
    private static func runAuthorization(
        _ request: PKPaymentRequest,
        confirm: @escaping @Sendable (WalletAuthorization) async -> CheckoutOutcome
    ) async throws -> CheckoutOutcome {
        throw CheckoutError(
            code: "WALLET_UNSUPPORTED_PLATFORM",
            message: "Apple Pay authorization is only available on iOS.",
            category: .runtime,
            traceId: nil
        )
    }
    #endif
}
