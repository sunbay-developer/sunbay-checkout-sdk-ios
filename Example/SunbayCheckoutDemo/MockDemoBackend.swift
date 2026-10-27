import Foundation
import SunbayCheckout

// MARK: - Scripted result (for the demo)

/// The terminal/intermediate-state scenario this demo wants `submit` to land on.
///
/// Lets the demo switch between the four `CheckoutOutcome`s (succeeded / failed / pending / unknown)
/// and `requiresAction` with one tap, all driven inside the mock backend so the UI needs no business branching.
public enum DemoScript: Sendable {
    /// Submit succeeds immediately (terminal S).
    case succeeded
    /// Submit fails immediately (terminal F).
    case failed
    /// Processing (non-terminal I) — the UI shows pending.
    case pending
    /// Requires further action (R).
    case requiresAction
    /// Submit timeout / network unavailable — Core enters unknown, then can recover via `getResult`.
    case networkTimeout
}

/// The "network unavailable" error thrown by the demo scenario (only used by `networkTimeout`).
///
/// A real backend's network failure is thrown by the adapter; here a minimal Error simulates a submit timeout,
/// letting `CheckoutController` take the unknown branch (§3.2: a submit timeout does not blindly retry, it queries getResult first).
private struct DemoNetworkUnavailable: Error {}

// MARK: - In-memory Mock PaymentService

/// An in-memory `PaymentService` for the demo, implementing the SDK's public protocol (the Task 11.5 injection seam).
///
/// - `loadSession` returns a scripted session: with the demo RSA **public key** (PKCS#1 DER base64, so
///   `CardEncryptor` can import and encrypt normally), `cofEnabled = true`, methods
///   `[.card, .applePay, .savedCard]`, an amount, and a merchant name.
/// - `submit` returns a scripted snapshot per `script` (success by default); `networkTimeout` throws to make Core enter unknown.
/// - `getResult` always returns a terminal snapshot (for the unknown-recovery demo).
///
/// Fully in-memory, no real backend, no secrets. Thread safety: fields are read-only or fixed at construction;
/// `script` is mutable but the demo drives on a single thread (a main-thread tap); annotated `@unchecked Sendable`
/// to satisfy the protocol's `Sendable`.
public final class MockDemoPaymentService: PaymentService, @unchecked Sendable {
    /// The scenario to demo this time (switchable in the demo UI).
    public var script: DemoScript

    public init(script: DemoScript = .succeeded) {
        self.script = script
    }

    public func loadSession(_ id: String) async throws -> CheckoutSession {
        CheckoutSession(
            id: id,
            amount: Amount(minorUnits: 4299, currencyCode: "USD"), // 42.99 USD
            merchantName: "Sunbay Demo Store",
            methods: [.card, .applePay, .savedCard],
            expiresAt: Date().addingTimeInterval(15 * 60), // expires in 15 minutes
            rsaPublicKey: DemoRSAKey.publicKeyPKCS1Base64,
            cofEnabled: true
        )
    }

    public func submit(_ req: SubmitRequest) async throws -> PaymentSnapshot {
        switch script {
        case .succeeded:
            return PaymentSnapshot(sessionId: req.sessionId, status: .succeeded, txnId: "demo_txn_\(req.attemptId.uuidString.prefix(8))")
        case .failed:
            return PaymentSnapshot(sessionId: req.sessionId, status: .failed, txnId: "demo_txn_\(req.attemptId.uuidString.prefix(8))")
        case .pending:
            return PaymentSnapshot(sessionId: req.sessionId, status: .initial, txnId: "demo_txn_\(req.attemptId.uuidString.prefix(8))")
        case .requiresAction:
            return PaymentSnapshot(sessionId: req.sessionId, status: .requiresAction, txnId: "demo_txn_\(req.attemptId.uuidString.prefix(8))")
        case .networkTimeout:
            // Simulate a submit timeout / network unavailable → Core enters unknown (no blind retry), then getResult recovers.
            throw DemoNetworkUnavailable()
        }
    }

    public func getResult(sessionId: String) async throws -> PaymentSnapshot {
        // Recovery demo: regardless of the previous scenario, the query returns a confirmed terminal state (success).
        PaymentSnapshot(sessionId: sessionId, status: .succeeded, txnId: "demo_txn_recovered")
    }
}

// MARK: - In-memory Mock CofService

/// An in-memory `CofService` for the demo, returning 1-2 scripted saved cards (COF one-tap pay demo).
public final class MockDemoCofService: CofService, @unchecked Sendable {
    public init() {}

    public func listPaymentMethods(customerAccessSecret: String, sessionId: String) async throws -> [SavedCard] {
        [
            SavedCard(id: "pm_demo_visa", brand: "visa", last4: "4242", expMonth: 12, expYear: 2029),
            SavedCard(id: "pm_demo_mc", brand: "mastercard", last4: "4444", expMonth: 8, expYear: 2028),
        ]
    }
}

// MARK: - Demo RSA public key (a one-off, committable demo public key)

/// A one-off generated **demo RSA public key** (PKCS#1 `RSAPublicKey` DER, base64).
///
/// - This is a **public key** (not a private key), generated once specifically for this demo and committable with
///   the source (see AGENTS.md: a public key is not confidential). The corresponding private key is **not committed**
///   and has been discarded — no real backend can decrypt with it; it purely lets `CardEncryptor` import and encrypt
///   successfully in the demo (producing a valid base64 ciphertext for the mock backend).
/// - The format matches `CardEncryptor`'s import convention: PKCS#1 DER directly importable via `SecKeyCreateWithData`
///   (kSecAttrKeyTypeRSA + kSecAttrKeyClassPublic). 2048-bit (blockSize 256).
/// - **Never** use this key in a real integration; the real public key is delivered by the backend via the session.
public enum DemoRSAKey {
    /// The demo public key, base64 of PKCS#1 DER (single line).
    public static let publicKeyPKCS1Base64 =
        "MIIBCgKCAQEAt65MyjQltDrA/Pl56ZlI9lMkXPB8dqbvrvbCljmZHUPHSDrp0fh4wxjA4iXkzI3OblbiXUZUEVmj+Htwqo9bSeVRXj3jD4HUgIPx13kyVqSifvH+EdCCL3q/+dWVqG+A/JtXrT/r2gtx0qG/d4WStLt6wn7BCwhL+JKs5ngJlQQbmQhajTukzLhY6pXiQKscw0LOWhxYa+y+xk5ILubcKbsDPP5MD12b1avQdc3IeygPRSEz5zBxLVEMgtJLRsfWcjbWpcsXiZQry8GnjjsOlpxPTVd7+fOnAIoHWDbunPktiXK+WcgGG2B4R26JxpP4UUjaUtpLFjLak/UwSt8HjQIDAQAB"
}
