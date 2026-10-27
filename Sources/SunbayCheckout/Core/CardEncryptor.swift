import Foundation
import Security

/// Plaintext bank card input (PAN / expiry / CVV).
///
/// This is the **only** value type that carries plaintext card data; it is assembled by the card
/// input control (a later UI task) and passed to `CardEncryptor.encrypt` for local encryption.
/// Once encryption completes, the caller should discard this instance immediately, and must not
/// log, persist, or send it back to the host (see security-and-pci.md §3/§4).
struct CardInput: Sendable {
    /// Card number (PAN).
    let cardNumber: String
    /// Expiry month (such as `"12"`).
    let expiryMonth: String
    /// Expiry year (such as `"2029"`).
    let expiryYear: String
    /// Security code (CVV/CVC).
    let cvv: String

    /// Creates a plaintext card input.
    ///
    /// - Parameters:
    ///   - cardNumber: Card number (PAN).
    ///   - expiryMonth: Expiry month.
    ///   - expiryYear: Expiry year.
    ///   - cvv: Security code.
    init(cardNumber: String, expiryMonth: String, expiryYear: String, cvv: String) {
        self.cardNumber = cardNumber
        self.expiryMonth = expiryMonth
        self.expiryYear = expiryYear
        self.cvv = cvv
    }
}

/// Error type for `CardEncryptor`.
///
/// None of the cases carry any card plaintext or ciphertext; they only distinguish the failure reason (see §5 zero log leakage).
enum CardEncryptorError: Error, Equatable {
    /// The provided base64 public key cannot be decoded into DER data.
    case invalidBase64Key
    /// The DER data cannot be imported as an RSA public key (format/length mismatch).
    case invalidPublicKey
    /// Failed to build JSON from the payload.
    case payloadSerializationFailed
    /// RSA chunked encryption failed (the underlying Security call returned an error).
    case encryptionFailed
    /// The key block size is too small to accommodate the PKCS#1 v1.5 overhead (key too small).
    case keyTooSmall
}

/// Local RSA encryption boundary for bank card data.
///
/// Corresponds to product-spec §7.2: assembles the plaintext JSON `{cardNumber, expiryMonth, expiryYear, cvv, timeStamp}`
/// (`timeStamp` is a millisecond string, generated in real time and never cached/reused), and encrypts it with the
/// base64 RSA public key issued by the session; **when the plaintext exceeds a single RSA block it is encrypted in chunks,
/// and the ciphertext chunks are concatenated in order and then base64-encoded as a whole**
/// (replicating the web `JSEncryptLong.encryptLong`, from which the backend decrypts chunk by chunk per blockSize).
///
/// Security boundary (security-and-pci.md §3/§4): this is the **only** unit in the whole library that touches plaintext card data;
/// the plaintext exists only in a transient local variable before encryption, and is released with its scope immediately after encryption; plaintext and ciphertext are never logged.
///
/// - Note: The public key import format is defined as **PKCS#1 DER** (`RSAPublicKey`), i.e. the native representation of
///   `SecKeyCopyExternalRepresentation` for an RSA public key, base64-encoded and passed in; this type imports it in the same
///   format via `SecKeyCreateWithData` (`kSecAttrKeyTypeRSA` + `kSecAttrKeyClassPublic`). If the backend issues an X.509
///   `SubjectPublicKeyInfo` (PEM `PUBLIC KEY`) wrapper, the SPKI header must be stripped before passing it in — this is a
///   point to align with the backend (§8.1).
enum CardEncryptor {
    /// RSA algorithm/padding choice.
    ///
    /// product-spec §8 D6: the padding must match the backend decryption. Isolated as a single constant, so once the backend confirms, only this one line changes.
    /// The web-side JSEncrypt defaults to PKCS#1 v1.5, so the first version aligns with `.rsaEncryptionPKCS1`.
    private static let rsaAlgorithm: SecKeyAlgorithm = .rsaEncryptionPKCS1

    /// The fixed overhead (bytes) of PKCS#1 v1.5 encryption.
    ///
    /// Max plaintext length per block = key block size − 11. Chunk if it exceeds this.
    private static let pkcs1Overhead = 11

    /// Locally encrypts card data and returns the base64 ciphertext submittable as `cardEncryptedData`.
    ///
    /// - Parameters:
    ///   - card: Plaintext card input.
    ///   - rsaPublicKeyBase64: The base64 RSA public key issued by the session (PKCS#1 DER, see the type comment).
    ///   - now: Time source, used to generate the millisecond timestamp; defaults to `Date.init`. Injected for testability.
    /// - Returns: A string of the chunked ciphertext concatenated in order and base64-encoded as a whole.
    /// - Throws: `CardEncryptorError` — thrown on an invalid public key or encryption failure; never returns a fabricated string.
    static func encrypt(
        _ card: CardInput,
        rsaPublicKeyBase64: String,
        now: () -> Date = Date.init
    ) throws -> String {
        let publicKey = try importPublicKey(base64: rsaPublicKeyBase64)

        // 1. Assemble the plaintext JSON (timeStamp is a millisecond string, generated in real time).
        let timeStamp = String(Int64(now().timeIntervalSince1970 * 1000))
        let payload: [String: String] = [
            "cardNumber": card.cardNumber,
            "expiryMonth": card.expiryMonth,
            "expiryYear": card.expiryYear,
            "cvv": card.cvv,
            "timeStamp": timeStamp,
        ]
        guard
            let plaintext = try? JSONSerialization.data(withJSONObject: payload)
        else {
            throw CardEncryptorError.payloadSerializationFailed
        }

        // 2. Encrypt in chunks per the key block size and concatenate (replicating encryptLong).
        let ciphertext = try encryptChunked(plaintext, with: publicKey)

        // 3. Base64-encode as a whole.
        return ciphertext.base64EncodedString()
    }

    // MARK: - Private

    /// Imports a base64 PKCS#1 DER public key as a `SecKey`.
    private static func importPublicKey(base64: String) throws -> SecKey {
        guard let der = Data(base64Encoded: base64) else {
            throw CardEncryptorError.invalidBase64Key
        }
        let attributes: [String: Any] = [
            kSecAttrKeyType as String: kSecAttrKeyTypeRSA,
            kSecAttrKeyClass as String: kSecAttrKeyClassPublic,
        ]
        var error: Unmanaged<CFError>?
        guard let key = SecKeyCreateWithData(der as CFData, attributes as CFDictionary, &error)
        else {
            // Do not pass through the underlying error details, to avoid potentially sensitive information reaching upper-layer logs.
            error?.release()
            throw CardEncryptorError.invalidPublicKey
        }
        return key
    }

    /// Chunks the plaintext per the key block size, RSA-encrypts each chunk, and concatenates them into a single `Data`.
    ///
    /// The max plaintext a single block can hold = `SecKeyGetBlockSize(key) - 11` (PKCS#1 v1.5 overhead).
    /// Each ciphertext block is always exactly the block size long, so the concatenated length = number of chunks × block size, from which the backend can split and restore precisely.
    private static func encryptChunked(_ plaintext: Data, with key: SecKey) throws -> Data {
        let blockSize = SecKeyGetBlockSize(key)
        let maxChunk = blockSize - pkcs1Overhead
        guard maxChunk > 0 else {
            throw CardEncryptorError.keyTooSmall
        }

        var ciphertext = Data()
        var offset = 0
        while offset < plaintext.count {
            let end = min(offset + maxChunk, plaintext.count)
            let chunk = plaintext.subdata(in: offset..<end)

            var error: Unmanaged<CFError>?
            guard
                let block = SecKeyCreateEncryptedData(
                    key,
                    rsaAlgorithm,
                    chunk as CFData,
                    &error
                ) as Data?
            else {
                error?.release()
                throw CardEncryptorError.encryptionFailed
            }
            ciphertext.append(block)
            offset = end
        }
        return ciphertext
    }
}
