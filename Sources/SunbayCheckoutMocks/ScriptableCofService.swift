import Foundation

import SunbayCheckout

/// Scriptable, public-API-only double for `CofService`.
///
/// Shared by the e2e test target and the Example app. Mirrors the scripting semantics of the
/// test-internal `MockCofService`: supports scripting the returned saved-card list or a thrown error,
/// and records the call count of `listPaymentMethods` plus the most recent arguments, used to assert
/// invariants such as "never list cards when COF is disabled". Mutable state is guarded with `NSLock`
/// to satisfy `Sendable`.
public final class ScriptableCofService: CofService, @unchecked Sendable {
    private let lock = NSLock()

    private var _cards: [SavedCard] = []
    private var _error: Error?

    private var _listCallCount = 0
    private var _lastCustomerAccessSecret: String?
    private var _lastSessionId: String?

    public var listCallCount: Int {
        lock.lock(); defer { lock.unlock() }
        return _listCallCount
    }

    public var lastCustomerAccessSecret: String? {
        lock.lock(); defer { lock.unlock() }
        return _lastCustomerAccessSecret
    }

    public var lastSessionId: String? {
        lock.lock(); defer { lock.unlock() }
        return _lastSessionId
    }

    public init() {}

    public func stubCards(_ cards: [SavedCard]) {
        lock.lock(); defer { lock.unlock() }
        _cards = cards
    }

    public func stubError(_ error: Error) {
        lock.lock(); defer { lock.unlock() }
        _error = error
    }

    public func listPaymentMethods(
        customerAccessSecret: String,
        sessionId: String
    ) async throws -> [SavedCard] {
        let (error, cards): (Error?, [SavedCard]) = {
            lock.lock(); defer { lock.unlock() }
            _listCallCount += 1
            _lastCustomerAccessSecret = customerAccessSecret
            _lastSessionId = sessionId
            return (_error, _cards)
        }()
        if let error { throw error }
        return cards
    }
}
