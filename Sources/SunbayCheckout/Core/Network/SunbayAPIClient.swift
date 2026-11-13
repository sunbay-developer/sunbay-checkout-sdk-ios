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

        return try await Self.decodeEnvelope(try await send(request))
    }

    /// Sends a JSON GET and decodes the envelope's `data`.
    ///
    /// GET is idempotent, so a transport failure is retried once before it is reported.
    ///
    /// - Parameters:
    ///   - route: Backend route.
    ///   - query: Query items appended to the route URL.
    ///   - timeout: Request timeout in seconds.
    /// - Returns: The decoded `data` of a successful envelope.
    /// - Throws: `CheckoutError` for every failure.
    func get<Response: Decodable & Sendable>(
        _ route: SunbayEndpoints.Route, query: [URLQueryItem] = [], timeout: TimeInterval = 15
    ) async throws -> Response {
        var url = SunbayEndpoints.url(for: route, environment: environment)
        if !query.isEmpty, var components = URLComponents(url: url, resolvingAgainstBaseURL: false) {
            components.queryItems = query
            url = components.url ?? url
        }
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.timeoutInterval = timeout
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("ios/\(SDKInfo.version)", forHTTPHeaderField: "X-Sunbay-SDK")
        if let locale { request.setValue(locale, forHTTPHeaderField: "Accept-Language") }

        let result: (Data, URLResponse)
        do {
            result = try await send(request)
        } catch {
            result = try await send(request)
        }
        return try Self.decodeEnvelope(result)
    }

    /// Sends a GET and returns the raw body and response for any HTTP status.
    ///
    /// For endpoints that are not enveloped (the card-rules document). Never retried: the caller decides
    /// what each status means. Only a transport failure throws (generic network `CheckoutError`).
    ///
    /// - Parameters:
    ///   - route: Backend route.
    ///   - headers: Extra request headers (for example `If-None-Match`).
    ///   - timeout: Request timeout in seconds.
    func getRaw(
        _ route: SunbayEndpoints.Route, headers: [String: String] = [:], timeout: TimeInterval = 3
    ) async throws -> (Data, HTTPURLResponse) {
        var request = URLRequest(url: SunbayEndpoints.url(for: route, environment: environment))
        request.httpMethod = "GET"
        request.timeoutInterval = timeout
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("ios/\(SDKInfo.version)", forHTTPHeaderField: "X-Sunbay-SDK")
        if let locale { request.setValue(locale, forHTTPHeaderField: "Accept-Language") }
        for (name, value) in headers { request.setValue(value, forHTTPHeaderField: name) }
        let (data, response) = try await send(request)
        guard let http = response as? HTTPURLResponse else { throw Self.invalidResponse() }
        return (data, http)
    }

    /// Performs the request; any transport failure becomes a generic network `CheckoutError`.
    private func send(_ request: URLRequest) async throws -> (Data, URLResponse) {
        #if DEBUG
        let logging = NetworkDebugLogger.isEnabled(environment: environment)
        let started = Date()
        if logging { NetworkDebugLogger.logRequest(request) }
        #endif
        do {
            let result = try await session.data(for: request)
            #if DEBUG
            if logging {
                NetworkDebugLogger.logResponse(result.0, result.1, url: request.url,
                                               elapsed: Date().timeIntervalSince(started))
            }
            #endif
            return result
        } catch {
            #if DEBUG
            if logging {
                NetworkDebugLogger.logFailure(url: request.url, elapsed: Date().timeIntervalSince(started))
            }
            #endif
            throw CheckoutError(code: "NETWORK_UNAVAILABLE", message: "The network request failed.",
                                category: .network, traceId: nil)
        }
    }

    /// Maps a raw response to the envelope's `data` or a `CheckoutError`.
    private static func decodeEnvelope<Response: Decodable & Sendable>(
        _ result: (Data, URLResponse)
    ) throws -> Response {
        let (data, response) = result
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        let decoder = JSONDecoder()

        // A 5xx is ambiguous (the request may have been processed), so it is always a network
        // failure regardless of any envelope body. The envelope traceId is kept; it is not secret.
        if status >= 500 {
            let traceId = (try? decoder.decode(ErrorEnvelope.self, from: data))?.traceId
            throw CheckoutError(code: "HTTP_\(status)", message: "The server returned an HTTP error.",
                                category: .network, traceId: traceId)
        }

        if let envelope = try? decoder.decode(ErrorEnvelope.self, from: data), let code = envelope.code {
            if code != "0" {
                throw CheckoutError(code: code, message: envelope.msg ?? "The payment request failed.",
                                    category: .payment, traceId: envelope.traceId)
            }
            guard (200..<300).contains(status),
                  let payload = try? decoder.decode(Envelope<Response>.self, from: data).data else {
                throw invalidResponse()
            }
            return payload
        }
        if !(200..<300).contains(status) {
            throw CheckoutError(code: "HTTP_\(status)", message: "The server returned an HTTP error.",
                                category: .network, traceId: nil)
        }
        throw invalidResponse()
    }

    private static func invalidResponse() -> CheckoutError {
        CheckoutError(code: "INVALID_RESPONSE", message: "The server response could not be processed.",
                      category: .network, traceId: nil)
    }
}
