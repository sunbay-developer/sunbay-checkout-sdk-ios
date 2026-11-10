import Foundation

/// Collects diagnostics, de-duplicates them, and delivers them to the host handler on the main thread.
///
/// Events raised before a handler is assigned are buffered (bounded) and replayed, in order, when one
/// is assigned. Never receives card values or secrets.
final class DiagnosticsReporter: @unchecked Sendable {
    private let lock = NSLock()
    private let maxBuffered: Int
    private var seen = Set<String>()
    private var buffer: [CheckoutDiagnostic] = []
    private var _handler: ((CheckoutDiagnostic) -> Void)?

    init(maxBuffered: Int = 50) {
        self.maxBuffered = maxBuffered
    }

    /// The host handler. Assigning replays any buffered events (in order) and clears the buffer.
    var handler: ((CheckoutDiagnostic) -> Void)? {
        get {
            lock.lock(); defer { lock.unlock() }
            return _handler
        }
        set {
            lock.lock()
            _handler = newValue
            let pending = buffer
            if newValue != nil { buffer.removeAll() }
            lock.unlock()
            guard newValue != nil else { return }
            for event in pending { deliver(event) }
        }
    }

    func warning(_ code: CheckoutWarning.Code, ignored: [String], reason: String, sessionId: String?) {
        let key = "\(code.rawValue):\(ignored.sorted().joined(separator: ","))"
        emit(
            .warning(CheckoutWarning(code: code, ignored: ignored, reason: reason, sessionId: sessionId)),
            key: key)
    }

    func error(_ error: CheckoutError, sessionId: String?) {
        emit(.error(error, sessionId: sessionId), key: "\(error.code):\(sessionId ?? "-")")
    }

    /// Forgets recorded warnings whose key mentions `identifier`, so the next one is delivered again.
    func resetWarnings(containing identifier: String) {
        lock.lock(); defer { lock.unlock() }
        seen = seen.filter { !$0.contains(identifier) }
    }

    /// Forgets errors reported without a session id (for example address-metadata failures), so a new
    /// start / dismiss lets the next such error through again.
    func resetUnscopedErrors() {
        lock.lock(); defer { lock.unlock() }
        seen = seen.filter { !$0.hasSuffix(":-") }
    }

    private func emit(_ event: CheckoutDiagnostic, key: String) {
        lock.lock()
        guard seen.insert(key).inserted else {
            lock.unlock()
            return
        }
        if _handler == nil {
            buffer.append(event)
            if buffer.count > maxBuffered { buffer.removeFirst(buffer.count - maxBuffered) }
        }
        let active = _handler != nil
        lock.unlock()
        if active { deliver(event) }
    }

    /// Always asynchronous on the main queue; the handler current at delivery time is used, so a
    /// replaced handler stops receiving.
    private func deliver(_ event: CheckoutDiagnostic) {
        DispatchQueue.main.async { [weak self] in
            self?.handler?(event)
        }
    }
}
