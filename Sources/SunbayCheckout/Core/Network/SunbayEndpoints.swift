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
        /// Lists the customer's saved cards.
        case cardList
        /// Lists the countries available for address collection.
        case addressCountries
        /// Loads the address field configuration of one country.
        case addressCountryConfig(code: String)
        /// The card-brand rules document (raw JSON, not enveloped).
        case cardRules
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
        let origin = origin(for: environment).absoluteString
        let checkoutBase = origin + "/api/checkout/web"
        let path: String
        switch route {
        case .loadSession(let id): path = checkoutBase + "/session/" + encode(id)
        case .submitPayment: path = checkoutBase + "/payment/submit"
        case .paymentResult(let sessionId): path = checkoutBase + "/payment/result/" + encode(sessionId)
        case .cardList: path = checkoutBase + "/card/list"
        case .addressCountries: path = origin + "/api/address/country"
        case .addressCountryConfig(let code): path = origin + "/api/address/country/" + encode(code)
        case .cardRules: path = origin + "/api/card/rules"
        }
        return URL(string: path)!
    }

    /// Percent-encodes an identifier so it stays a single path component.
    /// Only ASCII unreserved characters (RFC 3986) are left as-is; everything else is escaped,
    /// so the result is always ASCII-safe and `URL(string:)` cannot fail on it.
    static func encode(_ value: String) -> String {
        value.addingPercentEncoding(withAllowedCharacters: unreserved) ?? ""
    }

    private static let unreserved = CharacterSet(
        charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")
}
