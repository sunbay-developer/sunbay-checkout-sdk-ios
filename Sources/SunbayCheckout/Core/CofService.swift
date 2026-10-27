import Foundation

/// Backend capability contract for saved cards (COF) (UI-agnostic).
///
/// Corresponds to product-spec §7.5 (list cards). Uses `customerAccessSecret` (Customer Grant) +
/// `sessionId` to connect directly to the PSP; the scope is derived from the credential and does not
/// accept a client-supplied customerId. An unauthorized request returns 403 and must not be masked with an empty list.
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
}
