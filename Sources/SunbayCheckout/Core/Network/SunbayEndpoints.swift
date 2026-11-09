import Foundation

/// Builds backend URLs for each SDK environment. Hosts are fixed and never exposed publicly.
enum SunbayEndpoints {
    /// A backend route used by the SDK.
    enum Route: Equatable {
        /// Loads a checkout session by id.
        case loadSession(id: String)
        /// Submits a payment.
        case submitPayment
        /// Queries the payment result of a session.
        case paymentResult(sessionId: String)
    }

    /// Returns the backend origin for the given environment.
    static func origin(for environment: CheckoutConfiguration.Environment) -> URL {
        switch environment {
        case .dev: return URL(string: "https://checkout.sunbay-dev.com")!
        case .test: return URL(string: "https://checkout.sunbay-uat.us")!
        case .production: return URL(string: "https://checkout.sunbay.us")!
        }
    }

    /// Returns the full URL of a route in the given environment.
    static func url(for route: Route, environment: CheckoutConfiguration.Environment) -> URL {
        let base = origin(for: environment).absoluteString + "/api/checkout/web"
        let path: String
        switch route {
        case .loadSession(let id): path = "/session/" + encode(id)
        case .submitPayment: path = "/payment/submit"
        case .paymentResult(let sessionId): path = "/payment/result/" + encode(sessionId)
        }
        return URL(string: base + path)!
    }

    /// Percent-encodes an identifier so it stays a single path component.
    private static func encode(_ value: String) -> String {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        return value.addingPercentEncoding(withAllowedCharacters: allowed) ?? ""
    }
}
