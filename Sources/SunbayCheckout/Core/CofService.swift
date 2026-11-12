import Foundation

/// Backend capability contract for saved cards (COF) (UI-agnostic).
///
/// Corresponds to product-spec §7.5 (list cards). Uses `customerAccessSecret` (Customer Grant) +
/// `sessionId` to connect directly to the PSP; the scope is derived from the credential and does not
/// accept a client-supplied customerId.
///
/// The default `SunbayCheckout(configuration:)` uses the real `HTTPCofService` adapter. The controller
/// treats every listing failure (network, unauthorized, decoding) as "no saved cards" so listing never
/// blocks payment; it is never surfaced as a payment error.
///
/// - Note: **Public** since Task 11.5: the host injects its own implementation via `SunbayCheckout` to support COF card listing.
public protocol CofService: Sendable {
    /// Lists the saved cards available to the current Customer under this session.
    ///
    /// - Parameters:
    ///   - customerAccessSecret: Customer Grant credential (held in memory only, see §7.6).
    ///   - sessionId: Session identifier.
    /// - Returns: A list of saved card display information.
    func listPaymentMethods(customerAccessSecret: String, sessionId: String) async throws -> [SavedCard]

    /// Deletes (unbinds) a saved card.
    ///
    /// The default implementation throws a "not supported" `CheckoutError`, so existing host
    /// implementations keep compiling.
    ///
    /// - Parameters:
    ///   - savedCardId: Identifier of the saved card to delete.
    ///   - customerAccessSecret: Customer Grant credential (held in memory only, see §7.6).
    ///   - sessionId: Session identifier.
    func deleteCard(savedCardId: String, customerAccessSecret: String, sessionId: String) async throws
}

public extension CofService {
    func deleteCard(savedCardId: String, customerAccessSecret: String, sessionId: String) async throws {
        throw CheckoutErrors.cardDeleteUnsupported()
    }
}
