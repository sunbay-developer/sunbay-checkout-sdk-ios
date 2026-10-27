import Foundation

import SunbayCheckout

/// Builds a demo `CheckoutSession` shared by the e2e test target and the Example app.
///
/// The defaults mirror the current demo backend (`MockDemoBackend.swift`): a 42.99 USD amount,
/// the "Sunbay Demo Store" merchant, the `[.card, .applePay, .savedCard]` methods, a 15-minute
/// expiry, COF enabled, and the committable demo RSA **public key** (so `CardEncryptor` can import
/// and encrypt normally). Every parameter is defaulted so callers can override only what they need.
public enum DemoSessionFactory {
    /// Builds a demo session.
    ///
    /// - Parameters:
    ///   - id: Session identifier. Defaults to `"demo_session"`.
    ///   - amount: The amount to charge. Defaults to 42.99 USD.
    ///   - merchantName: The merchant display name. Defaults to `"Sunbay Demo Store"`.
    ///   - methods: Available payment methods. Defaults to `[.card, .applePay, .savedCard]`.
    ///   - expiresAt: Session expiry. Defaults to 15 minutes from now.
    ///   - rsaPublicKey: RSA public key (base64) for local card encryption. Defaults to the demo key.
    ///   - cofEnabled: Whether COF is enabled. Defaults to `true`.
    public static func make(
        id: String = "demo_session",
        amount: Amount = Amount(minorUnits: 4299, currencyCode: "USD"),
        merchantName: String = "Sunbay Demo Store",
        methods: Set<PaymentMethodKind> = [.card, .applePay, .savedCard],
        expiresAt: Date = Date().addingTimeInterval(15 * 60),
        rsaPublicKey: String = DemoRSAKey.publicKeyPKCS1Base64,
        cofEnabled: Bool = true
    ) -> CheckoutSession {
        CheckoutSession(
            id: id,
            amount: amount,
            merchantName: merchantName,
            methods: methods,
            expiresAt: expiresAt,
            rsaPublicKey: rsaPublicKey,
            cofEnabled: cofEnabled
        )
    }
}

/// The demo RSA public key (PKCS#1 `RSAPublicKey` DER, base64), shared by the e2e test target and
/// the Example app.
///
/// - This is a **public key** (not a private key), generated once specifically for this demo and
///   committable with the source (see AGENTS.md section 5: a public key is not confidential). The
///   corresponding private key is **not committed** and has been discarded, so no real backend can
///   decrypt with it; it purely lets `CardEncryptor` import and encrypt successfully in the demo
///   (producing a valid base64 ciphertext for the mock backend).
/// - The format matches `CardEncryptor`'s import convention: PKCS#1 DER directly importable via
///   `SecKeyCreateWithData` (kSecAttrKeyTypeRSA + kSecAttrKeyClassPublic). 2048-bit (blockSize 256).
/// - **Never** use this key in a real integration; the real public key is delivered by the backend
///   via the session.
public enum DemoRSAKey {
    /// The demo public key, base64 of PKCS#1 DER (single line).
    public static let publicKeyPKCS1Base64 =
        "MIIBCgKCAQEAt65MyjQltDrA/Pl56ZlI9lMkXPB8dqbvrvbCljmZHUPHSDrp0fh4wxjA4iXkzI3OblbiXUZUEVmj+Htwqo9bSeVRXj3jD4HUgIPx13kyVqSifvH+EdCCL3q/+dWVqG+A/JtXrT/r2gtx0qG/d4WStLt6wn7BCwhL+JKs5ngJlQQbmQhajTukzLhY6pXiQKscw0LOWhxYa+y+xk5ILubcKbsDPP5MD12b1avQdc3IeygPRSEz5zBxLVEMgtJLRsfWcjbWpcsXiZQry8GnjjsOlpxPTVd7+fOnAIoHWDbunPktiXK+WcgGG2B4R26JxpP4UUjaUtpLFjLak/UwSt8HjQIDAQAB"
}
