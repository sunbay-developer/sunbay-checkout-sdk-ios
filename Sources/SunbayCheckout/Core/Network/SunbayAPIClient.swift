import Foundation

/// SDK identification constants.
enum SDKInfo {
    /// The SDK version reported in the `X-Sunbay-SDK` header.
    static let version = "0.1.0"
}

/// Envelope-aware JSON POST client for the Sunbay backend.
///
/// Every failure is thrown as a `CheckoutError` with a fixed generic message; URLs, request or
/// response bodies and system error descriptions are never included.
struct SunbayAPIClient: Sendable {
    private let environment: CheckoutConfiguration.Environment
    private let locale: String?
    private let session: URLSession

    /// Creates a client.
    ///
    /// - Parameters:
    ///   - environment: Target backend environment.
    ///   - locale: Value for the `Accept-Language` header; omitted when nil.
    ///   - session: URL session used for requests.
    init(environment: CheckoutConfiguration.Environment, locale: String?,
         session: URLSession = SunbayAPIClient.makeSession()) {
        self.environment = environment
        self.locale = locale
        self.session = session
    }

    /// Creates a session that never caches or stores cookies.
    static func makeSession() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.urlCache = nil
        configuration.httpCookieStorage = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.waitsForConnectivity = false
        return URLSession(configuration: configuration)
    }

    /// Wire envelope returned by the backend.
    private struct Envelope<Data: Decodable>: Decodable {
        let code: String?
        let msg: String?
        let traceId: String?
        let data: Data?
    }

    /// Envelope variant used when the payload is irrelevant.
    private struct ErrorEnvelope: Decodable {
        let code: String?
        let msg: String?
        let traceId: String?
    }

    /// Sends a JSON POST and decodes the envelope's `data`.
    ///
    /// - Parameters:
    ///   - route: Backend route.
    ///   - body: Request body, encoded as JSON.
    ///   - timeout: Request timeout in seconds.
    /// - Returns: The decoded `data` of a successful envelope.
    /// - Throws: `CheckoutError` for every failure.
    func post<Body: Encodable & Sendable, Response: Decodable & Sendable>(
        _ route: SunbayEndpoints.Route, body: Body, timeout: TimeInterval = 15
    ) async throws -> Response {
        var request = URLRequest(url: SunbayEndpoints.url(for: route, environment: environment))
        request.httpMethod = "POST"
        request.timeoutInterval = timeout
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("ios/\(SDKInfo.version)", forHTTPHeaderField: "X-Sunbay-SDK")
        if let locale { request.setValue(locale, forHTTPHeaderField: "Accept-Language") }
        do {
            request.httpBody = try JSONEncoder().encode(body)
        } catch {
            throw Self.invalidResponse()
        }

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            throw CheckoutError(code: "NETWORK_UNAVAILABLE", message: "The network request failed.",
                                category: .network, traceId: nil)
        }
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        let decoder = JSONDecoder()

        if let envelope = try? decoder.decode(ErrorEnvelope.self, from: data), let code = envelope.code {
            if code != "0" {
                throw CheckoutError(code: code, message: envelope.msg ?? "The payment request failed.",
                                    category: .payment, traceId: envelope.traceId)
            }
            guard (200..<300).contains(status),
                  let payload = try? decoder.decode(Envelope<Response>.self, from: data).data else {
                throw Self.invalidResponse()
            }
            return payload
        }
        if !(200..<300).contains(status) {
            throw CheckoutError(code: "HTTP_\(status)", message: "The server returned an HTTP error.",
                                category: .network, traceId: nil)
        }
        throw Self.invalidResponse()
    }

    private static func invalidResponse() -> CheckoutError {
        CheckoutError(code: "INVALID_RESPONSE", message: "The server response could not be processed.",
                      category: .network, traceId: nil)
    }
}
