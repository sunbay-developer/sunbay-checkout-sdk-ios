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

    /// Creates a client.
    ///
    /// - Parameter serverURL: Base URL of the dev session server (for example `http://127.0.0.1:8095`).
    public init(serverURL: URL) {
        self.serverURL = serverURL
    }

    /// Creates a session through the dev server.
    ///
    /// - Parameters:
    ///   - amountMajorUnits: Order amount in major units (for example dollars); the server converts to minor units.
    ///   - collectBillingAddress: Whether the session should collect a billing address.
    /// - Returns: The created session.
    public func createSession(amountMajorUnits: Double = 0.01,
                              collectBillingAddress: Bool = false) async throws -> DevSession {
        var request = URLRequest(url: serverURL.appendingPathComponent("api/create-session"))
        request.httpMethod = "POST"
        request.timeoutInterval = 30
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let body: [String: Any] = [
            "amount": amountMajorUnits,
            "collectBillingAddress": collectBillingAddress,
        ]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await URLSession.shared.data(for: request)
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
