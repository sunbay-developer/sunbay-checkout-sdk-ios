import Foundation

@testable import SunbayCheckout

/// Scriptable test double for `CofService`.
///
/// Supports scripting the returned saved-card list or a thrown error, and records the call count of
/// `listPaymentMethods`, used to assert invariants such as "never list cards when COF is disabled".
/// Guards state with `NSLock` to satisfy `Sendable`.
final class MockCofService: CofService, @unchecked Sendable {
    private let lock = NSLock()

    private var _cards: [SavedCard] = []
    private var _error: Error?
    private var _deleteError: Error?

    private(set) var listCallCount = 0
    private(set) var lastCustomerAccessSecret: String?
    private(set) var lastSessionId: String?
    private(set) var deleteCallCount = 0
    private(set) var lastDeletedCardId: String?

    init() {}

    func stubCards(_ cards: [SavedCard]) {
        lock.lock(); defer { lock.unlock() }
        _cards = cards
    }

    func stubError(_ error: Error) {
        lock.lock(); defer { lock.unlock() }
        _error = error
    }

    func stubDeleteError(_ error: Error) {
        lock.lock(); defer { lock.unlock() }
        _deleteError = error
    }

    func deleteCard(savedCardId: String, customerAccessSecret: String, sessionId: String) async throws {
        let error: Error? = {
            lock.lock(); defer { lock.unlock() }
            deleteCallCount += 1
            lastDeletedCardId = savedCardId
            return _deleteError
        }()
        if let error { throw error }
    }

    func listPaymentMethods(
        customerAccessSecret: String,
        sessionId: String
    ) async throws -> [SavedCard] {
        let (error, cards): (Error?, [SavedCard]) = {
            lock.lock(); defer { lock.unlock() }
            listCallCount += 1
            lastCustomerAccessSecret = customerAccessSecret
            lastSessionId = sessionId
            return (_error, _cards)
        }()
        if let error { throw error }
        return cards
    }
}
