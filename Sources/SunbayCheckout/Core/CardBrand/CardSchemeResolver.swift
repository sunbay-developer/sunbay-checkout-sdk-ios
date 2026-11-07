import Foundation

/// Resolves the card scheme from the BIN using the HPP recognition endpoint (contract §4.2).
///
/// Triggers: query at exactly 6 and 9 digits; at 7 / 8 (or more than 9) only while no scheme is
/// known; below 6 digits cancel and drop the scheme; if the first 6 digits change, drop and query
/// again. Debounced, stale responses are ignored, results are cached per BIN in memory. Any failure is
/// silent (the caller keeps using local prefix matching). The BIN is never logged or persisted.
@MainActor
final class CardSchemeResolver {
    private let service: any CardBinService
    private let sessionId: String
    private let debounceNanoseconds: UInt64
    private let onChange: (String?) -> Void

    private(set) var scheme: String?
    private var schemeBIN6: String?
    private var sequence = 0
    private var task: Task<Void, Never>?
    private var cache: [String: String] = [:]

    /// - Parameters:
    ///   - service: The recognition service.
    ///   - sessionId: The checkout session id.
    ///   - debounce: Debounce interval in seconds (about 0.3 in production).
    ///   - onChange: Called on the main actor whenever the resolved scheme changes (nil = dropped).
    init(
        service: any CardBinService, sessionId: String, debounce: TimeInterval = 0.3,
        onChange: @escaping (String?) -> Void
    ) {
        self.service = service
        self.sessionId = sessionId
        self.debounceNanoseconds = UInt64(max(0, debounce) * 1_000_000_000)
        self.onChange = onChange
    }

    deinit { task?.cancel() }

    /// Feed the digits typed so far (digits only).
    func digitsChanged(_ digits: String) {
        let count = digits.count
        if count < 6 {
            invalidateInFlight()
            drop()
            return
        }
        let prefix6 = String(digits.prefix(6))
        if scheme != nil, prefix6 != schemeBIN6 {
            invalidateInFlight()
            drop()
        }
        let known = scheme != nil
        let shouldQuery =
            count == 6 || count == 9 || ((count == 7 || count == 8) && !known) || (count > 9 && !known)
        guard shouldQuery else { return }

        let bin = String(digits.prefix(9))
        if let cached = cache[bin] {
            apply(cached, bin6: prefix6)
            return
        }
        sequence += 1
        let mine = sequence
        task?.cancel()
        task = Task { [weak self] in
            guard let self else { return }
            try? await Task.sleep(nanoseconds: self.debounceNanoseconds)
            guard !Task.isCancelled else { return }
            let result = try? await self.service.recognize(bin: bin, sessionId: self.sessionId)
            guard mine == self.sequence, let result, !result.isEmpty else { return }
            let normalized = result.lowercased()
            self.cache[bin] = normalized
            self.apply(normalized, bin6: prefix6)
        }
    }

    private func invalidateInFlight() {
        sequence += 1
        task?.cancel()
    }

    private func drop() {
        guard scheme != nil else { return }
        scheme = nil
        schemeBIN6 = nil
        onChange(nil)
    }

    private func apply(_ value: String, bin6: String) {
        schemeBIN6 = bin6
        guard value != scheme else { return }
        scheme = value
        onChange(value)
    }
}
