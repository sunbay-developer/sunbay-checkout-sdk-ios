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

    func test_pendingEntersReconcilingWithInfoNotice() {
        var m = CheckoutStateMachine()
        m.beginProcessing()
        let r = m.apply(.pending(txnId: nil), localizedFailure: { _ in "" })
        XCTAssertEqual(m.state, .reconciling)
        XCTAssertEqual(r, .showInfoNotice)
    }

    func test_unknownEntersReconcilingWithInfoNotice() {
        var m = CheckoutStateMachine()
        m.beginProcessing()
        let r = m.apply(.unknown(sessionId: "s1"), localizedFailure: { _ in "" })
        XCTAssertEqual(m.state, .reconciling)
        XCTAssertEqual(r, .showInfoNotice)
    }

    /// The public coarse-grained state is unchanged for hosts: `.reconciling` still reports `.editing`
    /// (no new public enum case; public API stays additive-only).
    func test_reconcilingMapsToEditingPublicState() {
        var m = CheckoutStateMachine()
        m.beginProcessing()
        _ = m.apply(.unknown(sessionId: "s1"), localizedFailure: { _ in "" })
        XCTAssertEqual(m.presentationState, .editing)
    }

    /// A reconciling session can still receive a NEW outcome (e.g. a reconciled success or failure).
    func test_reconcilingThenSucceeded_isTerminalSuccess() {
        var m = CheckoutStateMachine()
        m.beginProcessing()
        _ = m.apply(.unknown(sessionId: "s1"), localizedFailure: { _ in "" })
        let r = m.apply(.succeeded(txnId: "t9"), localizedFailure: { _ in "" })
        XCTAssertEqual(m.state, .succeeded)
        XCTAssertEqual(r, .autoClose(.succeeded(txnId: "t9")))
    }
}
