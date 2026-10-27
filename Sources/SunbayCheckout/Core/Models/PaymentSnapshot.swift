import Foundation

/// Backend transaction status.
///
/// The raw values match the backend contract: `I` (initial / processing),
/// `S` (succeeded), `F` (failed), `R` (requires further action). `S` and `F`
/// are terminal states.
public enum TxnStatus: String, Sendable {
    /// Initial / processing.
    case initial = "I"
    /// Succeeded (terminal state).
    case succeeded = "S"
    /// Failed (terminal state).
    case failed = "F"
    /// Requires further action.
    case requiresAction = "R"
}

/// A snapshot of a single payment result query.
public struct PaymentSnapshot: Sendable, Equatable {
    /// Session identifier.
    public let sessionId: String
    /// Current transaction status.
    public let status: TxnStatus
    /// Transaction identifier; nil when not yet assigned.
    public let txnId: String?

    /// Creates a payment snapshot.
    ///
    /// - Parameters:
    ///   - sessionId: Session identifier.
    ///   - status: Current transaction status.
    ///   - txnId: Transaction identifier, may be nil.
    public init(sessionId: String, status: TxnStatus, txnId: String?) {
        self.sessionId = sessionId
        self.status = status
        self.txnId = txnId
    }
}
