import Foundation

@testable import SunbayCheckout

/// 可脚本化的 `CofService` 测试替身。
///
/// 支持脚本化返回的已保存卡列表或抛出的错误,并记录 `listPaymentMethods` 的调用次数,
/// 用于断言「COF 关闭时绝不调用列卡」等不变量。用 `NSLock` 保护状态以满足 `Sendable`。
final class MockCofService: CofService, @unchecked Sendable {
    private let lock = NSLock()

    private var _cards: [SavedCard] = []
    private var _error: Error?

    private(set) var listCallCount = 0
    private(set) var lastCustomerAccessSecret: String?
    private(set) var lastSessionId: String?

    init() {}

    func stubCards(_ cards: [SavedCard]) {
        lock.lock(); defer { lock.unlock() }
        _cards = cards
    }

    func stubError(_ error: Error) {
        lock.lock(); defer { lock.unlock() }
        _error = error
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
