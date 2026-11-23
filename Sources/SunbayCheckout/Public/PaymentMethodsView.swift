import Foundation

/// One payment method offered by the session (after the host's `PaymentMethodFilter`).
public struct PaymentMethodItem: Sendable, Equatable {
    /// Raw backend method, for example `VISA` or `APPLE_PAY`.
    public let method: String
    /// Backend type, for example `CARD` or `E_WALLET`.
    public let type: String
    /// Display name; may be empty.
    public let name: String
    /// Logo URL string; `nil` when the backend sent none.
    public let logoURL: String?
}

/// A quick wallet offered by the session, with whether this device can pay with it.
public struct ExpressMethodItem: Sendable, Equatable {
    /// Raw backend method, for example `APPLE_PAY`.
    public let method: String
    /// Backend type, for example `E_WALLET`.
    public let type: String
    /// Display name; may be empty.
    public let name: String
    /// Logo URL string; `nil` when the backend sent none.
    public let logoURL: String?
    /// `true` when an `ExpressCheckoutElement` would show this wallet: the device can pay, a merchant id
    /// and the wallet parameters are present, and `Appearance.expressPosition` is not `.off`.
    public let isAvailable: Bool
}

/// The session's payment methods split for layout decisions (`CheckoutElements.paymentMethods`).
///
/// Both lists keep the backend order after the host's `PaymentMethodFilter`; a hidden method is absent.
public struct PaymentMethodsView: Sendable, Equatable {
    /// Quick wallets (`APPLE_PAY`, `GOOGLE_PAY`) the session offers, available or not.
    public let express: [ExpressMethodItem]
    /// Every other method: card brands and other backend methods.
    public let regular: [PaymentMethodItem]
}

extension PaymentMethodsView {
    /// Splits `entries`; `applePayAvailable` is the device-side answer for `APPLE_PAY`.
    static func make(entries: [MethodEntry], applePayAvailable: Bool) -> PaymentMethodsView {
        var express: [ExpressMethodItem] = []
        var regular: [PaymentMethodItem] = []
        for entry in entries {
            if entry.method == "APPLE_PAY" || entry.method == "GOOGLE_PAY" {
                express.append(
                    ExpressMethodItem(
                        method: entry.method, type: entry.type, name: entry.name, logoURL: entry.logoURL,
                        isAvailable: entry.method == "APPLE_PAY" && applePayAvailable))
            } else {
                regular.append(
                    PaymentMethodItem(
                        method: entry.method, type: entry.type, name: entry.name, logoURL: entry.logoURL))
            }
        }
        return PaymentMethodsView(express: express, regular: regular)
    }
}
