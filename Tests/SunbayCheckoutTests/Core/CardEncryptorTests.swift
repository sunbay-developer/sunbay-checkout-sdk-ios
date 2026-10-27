import Foundation
import Security
import XCTest

@testable import SunbayCheckout

/// Round-trip tests for `CardEncryptor`.
///
/// The test generates a 2048-bit RSA key pair itself (Security framework), feeds the public key to
/// `encrypt`, then decrypts the chunks with the private key and concatenates them, verifying that
/// chunked encryption (mirroring web `encryptLong`) exactly restores the plaintext JSON.
///
/// Key import format convention: the public key is passed in as base64 of **PKCS#1 DER**
/// (`RSAPublicKey`, the native output of `SecKeyCopyExternalRepresentation` for an RSA public key);
/// `CardEncryptor` imports it in the same format via `SecKeyCreateWithData`.
final class CardEncryptorTests: XCTestCase {
    func test_encrypt_thenDecrypt_roundTrips_longPayload() throws {
        let (pub, priv) = try Self.makeRSAKeyPair(bits: 2048)
        let input = CardInput(
            cardNumber: "4242424242424242",
            expiryMonth: "12",
            expiryYear: "2029",
            cvv: "123"
        )

        let b64 = try CardEncryptor.encrypt(
            input,
            rsaPublicKeyBase64: pub,
            now: { Date(timeIntervalSince1970: 1_700_000_000) }
        )

        let json = try Self.rsaDecryptChunked(base64: b64, privateKey: priv)
        let obj = try XCTUnwrap(
            JSONSerialization.jsonObject(with: json) as? [String: String]
        )

        XCTAssertEqual(obj["cardNumber"], "4242424242424242")
        XCTAssertEqual(obj["cvv"], "123")
        XCTAssertEqual(obj["expiryMonth"], "12")
        XCTAssertEqual(obj["expiryYear"], "2029")
        XCTAssertEqual(obj["timeStamp"], "1700000000000")
    }

    /// Review Focus: when the plaintext JSON exceeds a single RSA block (245 bytes usable for 2048-bit),
    /// it must be chunked and must not be silently truncated. Builds an oversized cardNumber to push the
    /// payload past the single-block boundary, and asserts the round trip restores it exactly.
    func test_encrypt_thenDecrypt_roundTrips_forcesMultipleBlocks() throws {
        let (pub, priv) = try Self.makeRSAKeyPair(bits: 2048)
        // 400 digits, ensuring the serialized JSON clearly exceeds the single-block 245-byte usable capacity.
        let longCardNumber = String(repeating: "4", count: 400)
        let input = CardInput(
            cardNumber: longCardNumber,
            expiryMonth: "12",
            expiryYear: "2029",
            cvv: "123"
        )

        let b64 = try CardEncryptor.encrypt(
            input,
            rsaPublicKeyBase64: pub,
            now: { Date(timeIntervalSince1970: 1_700_000_000) }
        )

        // The ciphertext length must be an integer multiple of the block size (256 bytes) and more than one block, proving it was actually chunked.
        let cipher = try XCTUnwrap(Data(base64Encoded: b64))
        XCTAssertEqual(cipher.count % 256, 0, "ciphertext should be an integer multiple of the block size")
        XCTAssertGreaterThan(cipher.count, 256, "an oversized plaintext should produce more than one ciphertext block")

        let json = try Self.rsaDecryptChunked(base64: b64, privateKey: priv)
        let obj = try XCTUnwrap(
            JSONSerialization.jsonObject(with: json) as? [String: String]
        )

        XCTAssertEqual(obj["cardNumber"], longCardNumber)
        XCTAssertEqual(obj["cvv"], "123")
        XCTAssertEqual(obj["timeStamp"], "1700000000000")
    }

    func test_encrypt_invalidKey_throws() {
        let input = CardInput(
            cardNumber: "4242424242424242",
            expiryMonth: "12",
            expiryYear: "2029",
            cvv: "123"
        )

        XCTAssertThrowsError(
            try CardEncryptor.encrypt(input, rsaPublicKeyBase64: "not-a-valid-base64-der-key")
        )
    }

    // MARK: - Test crypto helpers

    /// Generates an RSA key pair.
    ///
    /// - Returns: `(publicKeyBase64DER, privateKey)`. The public key is a base64 string of PKCS#1 DER,
    ///   used to feed `CardEncryptor.encrypt`; the private key is a `SecKey` for decrypting within the test.
    static func makeRSAKeyPair(bits: Int) throws -> (publicBase64: String, privateKey: SecKey) {
        let attributes: [String: Any] = [
            kSecAttrKeyType as String: kSecAttrKeyTypeRSA,
            kSecAttrKeySizeInBits as String: bits,
        ]

        var error: Unmanaged<CFError>?
        guard let privateKey = SecKeyCreateRandomKey(attributes as CFDictionary, &error) else {
            throw error!.takeRetainedValue() as Error
        }
        guard let publicKey = SecKeyCopyPublicKey(privateKey) else {
            throw NSError(domain: "CardEncryptorTests", code: -1)
        }
        guard let der = SecKeyCopyExternalRepresentation(publicKey, &error) as Data? else {
            throw error!.takeRetainedValue() as Error
        }
        return (der.base64EncodedString(), privateKey)
    }

    /// Backend-side chunked decryption mirror: split the base64 ciphertext into block-sized segments,
    /// decrypt each block, and concatenate.
    ///
    /// Proves that `CardEncryptor`'s chunked concatenation can be exactly restored by a backend that
    /// "splits by blockSize and decrypts block by block".
    static func rsaDecryptChunked(base64: String, privateKey: SecKey) throws -> Data {
        guard let cipher = Data(base64Encoded: base64) else {
            throw NSError(domain: "CardEncryptorTests", code: -2)
        }
        let blockSize = SecKeyGetBlockSize(privateKey)
        XCTAssertGreaterThan(blockSize, 0)
        XCTAssertEqual(cipher.count % blockSize, 0, "the ciphertext length must be an integer multiple of the block size")

        var plaintext = Data()
        var offset = 0
        while offset < cipher.count {
            let block = cipher.subdata(in: offset..<(offset + blockSize))
            var error: Unmanaged<CFError>?
            guard
                let decrypted = SecKeyCreateDecryptedData(
                    privateKey,
                    .rsaEncryptionPKCS1,
                    block as CFData,
                    &error
                ) as Data?
            else {
                throw error!.takeRetainedValue() as Error
            }
            plaintext.append(decrypted)
            offset += blockSize
        }
        return plaintext
    }
}
