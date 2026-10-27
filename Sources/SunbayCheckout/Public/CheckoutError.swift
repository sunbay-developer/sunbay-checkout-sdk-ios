import Foundation

/// Error exposed externally during the checkout process.
///
/// This type is part of the public API. It carries error information that the host app can
/// display / report, but it never contains any sensitive data (card number, wallet token,
/// ciphertext, etc.).
public struct CheckoutError: Error, Sendable {
    /// Error category.
    public enum Category: Sendable, Equatable {
        /// Configuration error (e.g. missing required merchant configuration).
        case configuration
        /// Validation error (e.g. invalid card information).
        case validation
        /// Network error.
        case network
        /// Runtime error.
        case runtime
        /// Payment error (e.g. declined).
        case payment
    }

    /// Stable error code.
    public let code: String
    /// Developer-facing error description.
    public let message: String
    /// Error category.
    public let category: Category
    /// Backend trace identifier; nil when unavailable.
    public let traceId: String?

    /// Creates a checkout error.
    ///
    /// - Parameters:
    ///   - code: Stable error code.
    ///   - message: Developer-facing error description.
    ///   - category: Error category.
    ///   - traceId: Backend trace identifier, may be nil.
    public init(code: String, message: String, category: Category, traceId: String?) {
        self.code = code
        self.message = message
        self.category = category
        self.traceId = traceId
    }
}
