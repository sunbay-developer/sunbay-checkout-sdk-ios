import XCTest

@testable import SunbayCheckout

/// Unit tests for the pure-logic checkout view state machine (spec §3.1 / §3.2).
///
/// This suite is UIKit-free and runs under host `swift test` (no simulator needed): it exercises the
/// visible-state transitions and the `StepResult` the later content view controller (Task 8) acts on.
final class CheckoutStateMachineTests: XCTestCase {
    func test_successIsTerminalAndRequestsClose() {
        var m = CheckoutStateMachine()
        m.beginProcessing()
        let r = m.apply(.succeeded(txnId: "t1"), localizedFailure: { _ in "" })
        XCTAssertEqual(m.state, .succeeded)
        XCTAssertEqual(r, .autoClose(.succeeded(txnId: "t1")))
    }

    func test_failedStaysEditableWithReason() {
        var m = CheckoutStateMachine()
        m.beginProcessing()
        let err = CheckoutErrors.paymentFailed()
        let r = m.apply(.failed(txnId: nil, error: err), localizedFailure: { _ in "Insufficient funds." })
        XCTAssertEqual(m.state, .failed(reason: "Insufficient funds."))
        XCTAssertEqual(r, .showError("Insufficient funds."))
    }

    func test_pendingReturnsToEditingWithInfoNotice() {
        var m = CheckoutStateMachine()
        m.beginProcessing()
        let r = m.apply(.pending(txnId: nil), localizedFailure: { _ in "" })
        XCTAssertEqual(m.state, .editing)
        XCTAssertEqual(r, .showInfoNotice)
    }

    func test_unknownReturnsToEditingWithInfoNotice() {
        var m = CheckoutStateMachine()
        m.beginProcessing()
        let r = m.apply(.unknown(sessionId: "s1"), localizedFailure: { _ in "" })
        XCTAssertEqual(m.state, .editing)
        XCTAssertEqual(r, .showInfoNotice)
    }
}
