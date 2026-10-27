import Foundation
import Security
import XCTest

@testable import SunbayCheckout

/// `CardEncryptor` 的往返测试。
///
/// 测试内自行生成 2048 位 RSA 密钥对(Security framework),用公钥喂给 `encrypt`,
/// 再用私钥按块解密拼接,验证分块加密(对齐 web `encryptLong`)能精确还原明文 JSON。
///
/// 密钥导入格式约定:公钥以 **PKCS#1 DER**(`RSAPublicKey`,`SecKeyCopyExternalRepresentation`
/// 对 RSA 公钥的原生输出)base64 后传入;`CardEncryptor` 以同一格式经 `SecKeyCreateWithData` 导入。
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

    /// Review Focus:明文 JSON 超过单个 RSA 块(2048 位可用 245 字节)时必须分块,
    /// 不得静默截断。构造超长 cardNumber 把 payload 推过单块边界,断言往返精确还原。
    func test_encrypt_thenDecrypt_roundTrips_forcesMultipleBlocks() throws {
        let (pub, priv) = try Self.makeRSAKeyPair(bits: 2048)
        // 400 位数字,确保序列化后的 JSON 明显超过单块 245 字节可用容量。
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

        // 密文长度必须是块大小(256 字节)的整数倍,且多于一个块,证明确实分了块。
        let cipher = try XCTUnwrap(Data(base64Encoded: b64))
        XCTAssertEqual(cipher.count % 256, 0, "密文应为块大小的整数倍")
        XCTAssertGreaterThan(cipher.count, 256, "超长明文应产生多于一个密文块")

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

    /// 生成一对 RSA 密钥。
    ///
    /// - Returns: `(publicKeyBase64DER, privateKey)`。公钥为 PKCS#1 DER 的 base64 字符串,
    ///   用于喂给 `CardEncryptor.encrypt`;私钥为 `SecKey`,供测试内解密。
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

    /// 后端侧的分块解密镜像:把 base64 密文拆成块大小的片段,逐块解密后拼接。
    ///
    /// 证明 `CardEncryptor` 的分块拼接可被"按 blockSize 切分、逐块解密"的后端精确还原。
    static func rsaDecryptChunked(base64: String, privateKey: SecKey) throws -> Data {
        guard let cipher = Data(base64Encoded: base64) else {
            throw NSError(domain: "CardEncryptorTests", code: -2)
        }
        let blockSize = SecKeyGetBlockSize(privateKey)
        XCTAssertGreaterThan(blockSize, 0)
        XCTAssertEqual(cipher.count % blockSize, 0, "密文长度必须是块大小的整数倍")

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
