import XCTest

@testable import SunbayCheckout

final class DiagnosticsReporterTests: XCTestCase {
    private final class Box: @unchecked Sendable {
        private let lock = NSLock()
        private var items: [CheckoutDiagnostic] = []
        func add(_ d: CheckoutDiagnostic) { lock.lock(); items.append(d); lock.unlock() }
        var all: [CheckoutDiagnostic] { lock.lock(); defer { lock.unlock() }; return items }
    }

    private func flush() {
        let e = expectation(description: "main drained")
        DispatchQueue.main.async { e.fulfill() }
        wait(for: [e], timeout: 2)
    }

    private func err(_ code: String) -> CheckoutError {
        CheckoutError(code: code, message: "m", category: .network, traceId: nil)
    }

    private func codes(_ box: Box) -> [String] {
        box.all.map {
            switch $0 {
            case .warning(let w): return w.code.rawValue
            case .error(let e, _): return e.code
            }
        }
    }

    func test_warning_deliveredOnMainThread() {
        let reporter = DiagnosticsReporter()
        let e = expectation(description: "delivered")
        reporter.handler = { _ in
            XCTAssertTrue(Thread.isMainThread)
            e.fulfill()
        }
        DispatchQueue.global().async {
            reporter.warning(.paymentMethodFilterIgnored, ignored: ["x"], reason: "r", sessionId: "s")
        }
        wait(for: [e], timeout: 2)
    }

    func test_sameCodeAndIgnored_deliversOnce_differentIgnored_deliversBoth() {
        let reporter = DiagnosticsReporter()
        let box = Box()
        reporter.handler = { box.add($0) }
        reporter.warning(.addressIncomplete, ignored: ["b", "a"], reason: "r", sessionId: nil)
        reporter.warning(.addressIncomplete, ignored: ["a", "b"], reason: "r", sessionId: nil)
        reporter.warning(.addressIncomplete, ignored: ["c"], reason: "r", sessionId: nil)
        flush()
        XCTAssertEqual(box.all.count, 2)
    }

    func test_resetWarnings_allowsNextOne() {
        let reporter = DiagnosticsReporter()
        let box = Box()
        reporter.handler = { box.add($0) }
        reporter.warning(.addressIncomplete, ignored: ["billingAddress"], reason: "r", sessionId: nil)
        reporter.warning(.addressIncomplete, ignored: ["shippingAddress"], reason: "r", sessionId: nil)
        reporter.resetWarnings(containing: "billingAddress")
        reporter.warning(.addressIncomplete, ignored: ["billingAddress"], reason: "r", sessionId: nil)
        reporter.warning(.addressIncomplete, ignored: ["shippingAddress"], reason: "r", sessionId: nil)
        flush()
        XCTAssertEqual(box.all.count, 3)
    }

    func test_handlerAssignedLater_replaysBufferedInOrder_thenClears() {
        let reporter = DiagnosticsReporter()
        reporter.warning(.addressIncomplete, ignored: ["1"], reason: "r", sessionId: nil)
        reporter.error(err("E2"), sessionId: nil)
        reporter.warning(.walletParamsInvalid, ignored: ["3"], reason: "r", sessionId: nil)
        let box = Box()
        reporter.handler = { box.add($0) }
        flush()
        XCTAssertEqual(codes(box), ["ADDRESS_INCOMPLETE", "E2", "WALLET_PARAMS_INVALID"])
        let second = Box()
        reporter.handler = { second.add($0) }
        flush()
        XCTAssertTrue(second.all.isEmpty)
    }

    func test_bufferKeepsLast50() {
        let reporter = DiagnosticsReporter()
        for i in 0..<60 {
            reporter.warning(.addressIncomplete, ignored: ["f\(i)"], reason: "r", sessionId: nil)
        }
        let box = Box()
        reporter.handler = { box.add($0) }
        flush()
        XCTAssertEqual(box.all.count, 50)
        guard case .warning(let first) = box.all[0] else { return XCTFail("expected warning") }
        XCTAssertEqual(first.ignored, ["f10"])
    }

    func test_replacingHandler_stopsOldDelivery() {
        let reporter = DiagnosticsReporter()
        let old = Box()
        let new = Box()
        reporter.handler = { old.add($0) }
        reporter.handler = { new.add($0) }
        reporter.warning(.addressIncomplete, ignored: ["a"], reason: "r", sessionId: nil)
        flush()
        XCTAssertTrue(old.all.isEmpty)
        XCTAssertEqual(new.all.count, 1)
    }

    func test_errors_dedupPerCodeAndSession_orderPreserved() {
        let reporter = DiagnosticsReporter()
        let box = Box()
        reporter.handler = { box.add($0) }
        reporter.error(err("A"), sessionId: "s1")
        reporter.warning(.addressIncomplete, ignored: ["x"], reason: "r", sessionId: nil)
        reporter.error(err("A"), sessionId: "s1")
        reporter.error(err("A"), sessionId: "s2")
        flush()
        XCTAssertEqual(codes(box), ["A", "ADDRESS_INCOMPLETE", "A"])
    }

    func test_payloadEquality() {
        let a = CheckoutWarning(code: .addressEntryIgnored, ignored: ["x"], reason: "r", sessionId: "s")
        let b = CheckoutWarning(code: "ADDRESS_ENTRY_IGNORED", ignored: ["x"], reason: "r", sessionId: "s")
        XCTAssertEqual(a, b)
        XCTAssertEqual(CheckoutDiagnostic.warning(a), CheckoutDiagnostic.warning(b))
    }
}
