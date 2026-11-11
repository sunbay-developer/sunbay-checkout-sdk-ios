import Foundation

/// A checkout session created by the dev session server.
public struct DevSession: Sendable {
    /// The session identifier.
    public let sessionId: String
    /// The checkout client secret used to load and submit the session.
    public let checkoutClientSecret: String
    /// The customer access secret for saved cards, if the server returned one.
    public let customerAccessSecret: String?

    /// Creates a dev session value.
    public init(sessionId: String, checkoutClientSecret: String, customerAccessSecret: String?) {
        self.sessionId = sessionId
        self.checkoutClientSecret = checkoutClientSecret
        self.customerAccessSecret = customerAccessSecret
    }
}

/// Failure creating a dev session. Carries no response body, to avoid leaking secrets.
public struct DevSessionError: Error, Sendable, CustomStringConvertible {
    /// A short description without secrets or response bodies.
    public let description: String
}

/// Client for the dev-only session server in `Example/DevServer`.
///
/// DEV ONLY. This server holds merchant API credentials. In production, create the session in YOUR backend; never put the API key in an app.
///
/// This test-support target is not for production use.
public struct DevSessionClient: Sendable {
    private let serverURL: URL
    private let session: URLSession

    /// Creates a client that uses `URLSession.shared`.
    ///
    /// - Parameter serverURL: Base URL of the dev session server (for example `http://127.0.0.1:8095`).
    public init(serverURL: URL) {
        self.init(serverURL: serverURL, session: .shared)
    }

    /// Creates a client with an explicit URL session (tests inject a stubbed one).
    ///
    /// - Parameters:
    ///   - serverURL: Base URL of the dev session server.
    ///   - session: The URL session used for the request.
    public init(serverURL: URL, session: URLSession) {
        self.serverURL = serverURL
        self.session = session
    }

    /// Creates a session through the dev server.
    ///
    /// - Parameters:
    ///   - amountMajorUnits: Order amount in major units (for example dollars); the server converts to minor units.
    ///   - taxMajorUnits: Tax in major units, added on top of the amount. Defaults to `0`.
    ///   - collectBillingAddress: Whether the session should collect a billing address.
    ///   - collectShippingAddress: Whether the session should collect a shipping address.
    ///   - supportStoreCard: Whether the session allows saved cards. Defaults to `true`.
    ///   - customerId: The user identifier saved cards are scoped to; `nil` uses the server's configured one.
    /// - Returns: The created session.
    public func createSession(amountMajorUnits: Double = 0.01,
                              taxMajorUnits: Double = 0,
                              collectBillingAddress: Bool = false,
                              collectShippingAddress: Bool = false,
                              supportStoreCard: Bool = true,
                              customerId: String? = nil) async throws -> DevSession {
        var request = URLRequest(url: serverURL.appendingPathComponent("api/create-session"))
        request.httpMethod = "POST"
        request.timeoutInterval = 30
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        var body: [String: Any] = [
            "amount": amountMajorUnits,
            "taxAmount": taxMajorUnits,
            "collectBillingAddress": collectBillingAddress,
            "collectShippingAddress": collectShippingAddress,
            "supportStoreCard": supportStoreCard,
        ]
        if let customerId, !customerId.isEmpty { body["customerId"] = customerId }
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await session.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard status == 200 else {
            throw DevSessionError(description: "Dev session server returned HTTP \(status).")
        }
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let sessionId = object["sessionId"] as? String,
              let secret = object["checkoutClientSecret"] as? String else {
            throw DevSessionError(description: "Dev session server returned an unexpected response.")
        }
        return DevSession(sessionId: sessionId, checkoutClientSecret: secret,
                          customerAccessSecret: object["customerAccessSecret"] as? String)
    }
}
