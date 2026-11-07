import Foundation
import SunbayCheckout

/// Simulated payment backend for the Showcase app. Conforms only to the public SDK protocol.
///
/// The transaction id is generated lazily on the first `submit` and then stays stable for the
/// lifetime of the instance, so `getResult` reports the same transaction.
public final class ShowcasePaymentService: PaymentService, @unchecked Sendable {
    private let amountMinor: Int64
    private let sessionId: String
    private let lock = NSLock()
    private var txnId: String?

    public init(amountMinor: Int64, sessionId: String) {
        self.amountMinor = amountMinor
        self.sessionId = sessionId
    }

    public func loadSession(_ id: String) async throws -> CheckoutSession {
        CheckoutSession(
            id: id,
            amount: Amount(minorUnits: amountMinor, currencyCode: "USD"),
            merchantName: "Showcase Store",
            methods: [.card, .applePay, .savedCard],
            expiresAt: Date().addingTimeInterval(15 * 60),
            rsaPublicKey: ShowcaseRSAKey.publicKeyBase64,
            cofEnabled: true
        )
    }

    public func submit(_ req: SubmitRequest) async throws -> PaymentSnapshot {
        // The sessionId argument is ignored: this mock serves a single session.
        try await Task.sleep(nanoseconds: 1_000_000_000)
        return PaymentSnapshot(sessionId: sessionId, status: .succeeded, txnId: currentTxnId())
    }

    public func getResult(sessionId: String) async throws -> PaymentSnapshot {
        // The sessionId argument is ignored: this mock serves a single session.
        PaymentSnapshot(sessionId: self.sessionId, status: .succeeded, txnId: currentTxnId())
    }

    private func currentTxnId() -> String {
        lock.lock(); defer { lock.unlock() }
        if let txnId { return txnId }
        let alphabet = Array("abcdefghijklmnopqrstuvwxyz0123456789")
        let suffix = String((0..<8).map { _ in alphabet.randomElement()! })
        let generated = "txn_" + suffix
        txnId = generated
        return generated
    }
}

/// Simulated saved-card (COF) service returning two fixed cards.
public final class ShowcaseCofService: CofService, @unchecked Sendable {
    public init() {}

    public func listPaymentMethods(
        customerAccessSecret: String,
        sessionId: String
    ) async throws -> [SavedCard] {
        [
            SavedCard(id: "pm_demo_visa", brand: "visa", last4: "4242", expMonth: 12, expYear: 2029),
            SavedCard(id: "pm_demo_mc", brand: "mastercard", last4: "4444", expMonth: 8, expYear: 2028),
        ]
    }
}

/// Demo RSA public key (PKCS#1 DER, base64). Public and non-confidential; the private key was
/// discarded, so it only lets local card encryption succeed against the simulated backend.
enum ShowcaseRSAKey {
    static let publicKeyBase64 =
        "MIIBCgKCAQEAt65MyjQltDrA/Pl56ZlI9lMkXPB8dqbvrvbCljmZHUPHSDrp0fh4wxjA4iXkzI3OblbiXUZUEVmj+Htwqo9bSeVRXj3jD4HUgIPx13kyVqSifvH+EdCCL3q/+dWVqG+A/JtXrT/r2gtx0qG/d4WStLt6wn7BCwhL+JKs5ngJlQQbmQhajTukzLhY6pXiQKscw0LOWhxYa+y+xk5ILubcKbsDPP5MD12b1avQdc3IeygPRSEz5zBxLVEMgtJLRsfWcjbWpcsXiZQry8GnjjsOlpxPTVd7+fOnAIoHWDbunPktiXK+WcgGG2B4R26JxpP4UUjaUtpLFjLak/UwSt8HjQIDAQAB"
}
