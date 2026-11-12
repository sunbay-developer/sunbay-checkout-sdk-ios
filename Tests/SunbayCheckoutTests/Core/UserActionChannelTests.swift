import XCTest

@testable import SunbayCheckout

/// Behavior of the user-action plumbing shared by the presentation shells: a user action that arrives
/// while nobody is suspended must be buffered (never dropped), only one is buffered (first wins), and a
/// cancel always wins.
@MainActor
final class UserActionChannelTests: XCTestCase {
    private func isCancel(_ action: CheckoutUserAction) -> Bool {
        if case .cancel = action { return true }
        return false
    }

    private func savedCardId(_ action: CheckoutUserAction) -> String? {
        if case let .confirmSavedCard(id) = action { return id }
        return nil
    }

    func test_next_returnsActionPostedWhileSuspended() async {
        let channel = UserActionChannel()
        let waiter = Task { await channel.next() }
        await Task.yield()
        channel.post(.confirmSavedCard(paymentMethodId: "pm_1"))
        let action = await waiter.value
        XCTAssertEqual(savedCardId(action), "pm_1")
    }

    func test_post_beforeNext_isBufferedAndDelivered() async {
        let channel = UserActionChannel()
        channel.post(.confirmSavedCard(paymentMethodId: "pm_1"))
        let action = await channel.next()
        XCTAssertEqual(savedCardId(action), "pm_1")
    }

    func test_secondPostWhileBuffered_isIgnored_firstWins() async {
        let channel = UserActionChannel()
        channel.post(.confirmSavedCard(paymentMethodId: "pm_1"))
        channel.post(.confirmSavedCard(paymentMethodId: "pm_2"))
        let first = await channel.next()
        XCTAssertEqual(savedCardId(first), "pm_1")

        // pm_2 was dropped: the next suspended call is satisfied only by a new post.
        let waiter = Task { await channel.next() }
        await Task.yield()
        channel.post(.confirmSavedCard(paymentMethodId: "pm_3"))
        let second = await waiter.value
        XCTAssertEqual(savedCardId(second), "pm_3")
    }

    func test_cancelReplacesBufferedAction() async {
        let channel = UserActionChannel()
        channel.post(.confirmSavedCard(paymentMethodId: "pm_1"))
        channel.post(.cancel)
        let action = await channel.next()
        XCTAssertTrue(isCancel(action))
    }

    func test_cancel_setsWasCanceled_andResumesSuspendedNext() async {
        let channel = UserActionChannel()
        XCTAssertFalse(channel.wasCanceled)
        let waiter = Task { await channel.next() }
        await Task.yield()
        channel.cancel()
        let action = await waiter.value
        XCTAssertTrue(isCancel(action))
        XCTAssertTrue(channel.wasCanceled)
    }

    func test_cancelWinsOverLaterPost_andKeepsReturningCancel() async {
        let channel = UserActionChannel()
        channel.cancel()
        channel.post(.confirmSavedCard(paymentMethodId: "pm_9"))
        let first = await channel.next()
        let second = await channel.next()
        XCTAssertTrue(isCancel(first))
        XCTAssertTrue(isCancel(second))
    }

    func test_postCancel_doesNotSetWasCanceled_butIsDelivered() async {
        let channel = UserActionChannel()
        channel.post(.cancel)
        XCTAssertFalse(channel.wasCanceled)
        let action = await channel.next()
        XCTAssertTrue(isCancel(action))
    }
}
