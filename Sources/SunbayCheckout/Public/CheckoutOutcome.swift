import Foundation

/// The result returned externally by a checkout flow.
///
/// This enum is part of the public API; it expresses the terminal and intermediate states
/// of checkout, and never contains any sensitive data.
public enum CheckoutOutcome: Sendable {
    /// Payment succeeded, carrying the transaction identifier.
    case succeeded(txnId: String)
    /// Payment failed, carrying the transaction identifier (may be nil) and error information.
    case failed(txnId: String?, error: CheckoutError)
    /// The user canceled.
    case canceled
    /// Payment is processing (non-terminal state), carrying the transaction identifier (may be nil).
    case pending(txnId: String?)
    /// Result unknown (e.g. cannot be confirmed after a submit timeout), carrying the session identifier for subsequent lookup.
    case unknown(sessionId: String)
}
