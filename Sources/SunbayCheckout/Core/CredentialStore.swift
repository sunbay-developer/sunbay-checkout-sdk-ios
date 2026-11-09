/// Cohesive boundary that holds sensitive credentials (customerAccessSecret / checkoutClientSecret) in memory.
///
/// Security constraints (see `docs/security-and-pci.md` §3 item 3/7, §4):
/// - **In-memory only**: a single optional `String` property; never written to UserDefaults / files / Keychain / clipboard.
/// - **Zero log leakage**: never print / os_log / log analytics / crash-report any secret value.
/// - **Cleared on success / dismiss / expiry**: `clear()` is called by the controller on `.succeeded`, `dismiss()` and session expiry; NOT on `.failed` / `.unknown` / pending, so a host-visible retry still carries the secrets (ruling R7); idempotent.
///
/// `actor` isolation guarantees mutual exclusion under concurrent access; internal and not exposed (non-`public`).
actor CredentialStore {
    /// The currently held secret; `nil` means not held or already cleared. In-memory only.
    private var secret: String?

    /// The held checkout client secret; in-memory only.
    private var clientSecret: String?

    init() {}

    /// Holds the checkout client secret (overwriting any existing value).
    func hold(checkoutClientSecret: String) {
        clientSecret = checkoutClientSecret
    }

    /// Reads the held checkout client secret, or `nil`.
    func currentCheckoutClientSecret() -> String? {
        clientSecret
    }

    /// Holds a secret (overwriting any existing value).
    /// - Parameter customerAccessSecret: A short-TTL credential value; held in memory only, never persisted or logged.
    func hold(customerAccessSecret: String) {
        secret = customerAccessSecret
    }

    /// Reads the currently held secret.
    /// - Returns: Its value if held, otherwise `nil`.
    func current() -> String? {
        secret
    }

    /// Clears both held secrets. Idempotent: calling it again when already empty is safe and has no side effects.
    func clear() {
        secret = nil
        clientSecret = nil
    }
}
