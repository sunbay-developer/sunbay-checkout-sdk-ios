import Foundation

#if DEBUG
import os

/// Debug-only HTTP request/response logger.
///
/// Three gates must all pass, otherwise nothing is logged:
/// 1. The code exists only in `DEBUG` builds (it is not compiled into a host's Release build).
/// 2. The client targets the `.dev` environment.
/// 3. The process was launched with the `-SunbayNetworkLog` argument.
///
/// Sensitive JSON values are redacted by key before anything is printed (see `redact`); non-JSON
/// bodies are never printed, only their size. Output goes to `os.Logger` (subsystem
/// `com.sunbay.checkout`, category `network`), never to a file.
enum NetworkDebugLogger {
    /// Launch argument that opts in to network logging.
    static let launchArgument = "-SunbayNetworkLog"

    private static let logger = Logger(subsystem: "com.sunbay.checkout", category: "network")

    /// Case-insensitive key fragments whose values are always replaced.
    private static let sensitiveKeyFragments = [
        "secret", "token", "encrypt", "cipher", "cvv", "cvc", "password", "authorization",
        "signature", "apikey", "privatekey", "cardnumber", "securitycode"
    ]

    static let redactedPlaceholder = "<redacted>"

    /// Returns whether logging is enabled for the environment and launch arguments.
    static func isEnabled(
        environment: CheckoutConfiguration.Environment,
        arguments: [String] = ProcessInfo.processInfo.arguments
    ) -> Bool {
        environment == .dev && arguments.contains(launchArgument)
    }

    /// Logs an outgoing request.
    static func logRequest(_ request: URLRequest) {
        let method = request.httpMethod ?? "GET"
        let url = request.url?.absoluteString ?? "-"
        let headers = redactHeaders(request.allHTTPHeaderFields ?? [:])
        let body = describeBody(request.httpBody)
        logger.debug("➡️ \(method, privacy: .public) \(url, privacy: .public)\nheaders: \(headers, privacy: .public)\nbody: \(body, privacy: .public)")
    }

    /// Logs a received response.
    static func logResponse(_ data: Data, _ response: URLResponse, url: URL?, elapsed: TimeInterval) {
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        let millis = Int(elapsed * 1000)
        let target = url?.absoluteString ?? "-"
        let body = describeBody(data)
        logger.debug("⬅️ \(status, privacy: .public) \(target, privacy: .public) (\(millis, privacy: .public) ms)\nbody: \(body, privacy: .public)")
    }

    /// Logs a transport failure without the system error description.
    static func logFailure(url: URL?, elapsed: TimeInterval) {
        let target = url?.absoluteString ?? "-"
        let millis = Int(elapsed * 1000)
        logger.debug("❌ transport failure \(target, privacy: .public) (\(millis, privacy: .public) ms)")
    }

    // MARK: - Redaction

    /// Replaces every value whose key matches a sensitive fragment, at any depth.
    static func redact(_ value: Any) -> Any {
        if let dictionary = value as? [String: Any] {
            return dictionary.reduce(into: [String: Any]()) { result, pair in
                result[pair.key] = isSensitive(key: pair.key) ? redactedPlaceholder : redact(pair.value)
            }
        }
        if let array = value as? [Any] {
            return array.map(redact)
        }
        return value
    }

    static func redactHeaders(_ headers: [String: String]) -> [String: String] {
        headers.reduce(into: [:]) { result, pair in
            result[pair.key] = isSensitive(key: pair.key) ? redactedPlaceholder : pair.value
        }
    }

    /// Returns redacted pretty JSON, or only the byte count when the body is not JSON.
    static func describeBody(_ data: Data?) -> String {
        guard let data, !data.isEmpty else { return "<empty>" }
        guard let object = try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed]),
              let redacted = try? JSONSerialization.data(
                withJSONObject: redact(object), options: [.prettyPrinted, .sortedKeys, .fragmentsAllowed]),
              let text = String(data: redacted, encoding: .utf8) else {
            return "<non-JSON body, \(data.count) bytes>"
        }
        return text
    }

    private static func isSensitive(key: String) -> Bool {
        let lowered = key.lowercased().filter { $0.isLetter || $0.isNumber }
        return sensitiveKeyFragments.contains { lowered.contains($0) }
    }
}
#endif
