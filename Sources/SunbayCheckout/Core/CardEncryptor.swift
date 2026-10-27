import Foundation
import Security

/// 银行卡明文输入(PAN / 有效期 / CVV)。
///
/// 这是**唯一**承载明文卡数据的值类型,由卡输入控件(后续 UI 任务)装配,
/// 交给 `CardEncryptor.encrypt` 本地加密。加密完成后调用方应立即丢弃该实例,
/// 不得记录日志、持久化或回传宿主(见 security-and-pci.md §3/§4)。
struct CardInput: Sendable {
    /// 卡号(PAN)。
    let cardNumber: String
    /// 有效期月份(如 `"12"`)。
    let expiryMonth: String
    /// 有效期年份(如 `"2029"`)。
    let expiryYear: String
    /// 安全码(CVV/CVC)。
    let cvv: String

    /// 创建一份卡明文输入。
    ///
    /// - Parameters:
    ///   - cardNumber: 卡号(PAN)。
    ///   - expiryMonth: 有效期月份。
    ///   - expiryYear: 有效期年份。
    ///   - cvv: 安全码。
    init(cardNumber: String, expiryMonth: String, expiryYear: String, cvv: String) {
        self.cardNumber = cardNumber
        self.expiryMonth = expiryMonth
        self.expiryYear = expiryYear
        self.cvv = cvv
    }
}

/// `CardEncryptor` 的错误类型。
///
/// 所有 case 均不携带任何卡明文或密文,仅用于区分失败原因(见 §5 零日志泄漏)。
enum CardEncryptorError: Error, Equatable {
    /// 传入的 base64 公钥无法解码为 DER 数据。
    case invalidBase64Key
    /// DER 数据无法导入为 RSA 公钥(格式/长度不符)。
    case invalidPublicKey
    /// 由 payload 构造 JSON 失败。
    case payloadSerializationFailed
    /// RSA 分块加密失败(底层 Security 调用返回错误)。
    case encryptionFailed
    /// 密钥块大小不足以容纳 PKCS#1 v1.5 开销(密钥过小)。
    case keyTooSmall
}

/// 银行卡数据的 RSA 本地加密边界。
///
/// 对应 product-spec §7.2:组装 `{cardNumber, expiryMonth, expiryYear, cvv, timeStamp}`
/// 明文 JSON(`timeStamp` 为毫秒字符串,实时生成、不可缓存复用),用 session 下发的
/// base64 RSA 公钥加密;**明文超过单个 RSA 块时分块加密,密文按序拼接后整体 base64**
/// (复刻 web `JSEncryptLong.encryptLong`,后端据此按 blockSize 切分逐块解密)。
///
/// 安全边界(security-and-pci.md §3/§4):这是全库**唯一**接触明文卡数据的单元;
/// 明文仅存在于加密前的瞬时局部变量,加密后立即随作用域释放;绝不记录明文或密文。
///
/// - Note: 公钥导入格式约定为 **PKCS#1 DER**(`RSAPublicKey`),即 `SecKeyCopyExternalRepresentation`
///   对 RSA 公钥的原生表示,base64 后传入;本类以同一格式经 `SecKeyCreateWithData`
///   (`kSecAttrKeyTypeRSA` + `kSecAttrKeyClassPublic`)导入。若后端下发的是 X.509
///   `SubjectPublicKeyInfo`(PEM `PUBLIC KEY`)包装,需先剥离 SPKI 头部再传入——这是
///   与后端对齐的点(§8.1)。
enum CardEncryptor {
    /// RSA 算法/padding 选择。
    ///
    /// product-spec §8 D6:padding 必须与后端解密一致。隔离为单一常量,后端确认后改此一行即可。
    /// web 侧 JSEncrypt 默认 PKCS#1 v1.5,故首版对齐 `.rsaEncryptionPKCS1`。
    private static let rsaAlgorithm: SecKeyAlgorithm = .rsaEncryptionPKCS1

    /// PKCS#1 v1.5 加密的固定开销(字节)。
    ///
    /// 单块最大明文长度 = 密钥块大小 − 11。超出即分块。
    private static let pkcs1Overhead = 11

    /// 本地加密一份卡数据,返回可作为 `cardEncryptedData` 提交的 base64 密文。
    ///
    /// - Parameters:
    ///   - card: 卡明文输入。
    ///   - rsaPublicKeyBase64: session 下发的 base64 RSA 公钥(PKCS#1 DER,见类型注释)。
    ///   - now: 时间源,用于生成毫秒时间戳;默认 `Date.init`。注入便于测试。
    /// - Returns: 分块密文按序拼接后整体 base64 的字符串。
    /// - Throws: `CardEncryptorError`——无效公钥或加密失败时抛出,绝不返回伪造字符串。
    static func encrypt(
        _ card: CardInput,
        rsaPublicKeyBase64: String,
        now: () -> Date = Date.init
    ) throws -> String {
        let publicKey = try importPublicKey(base64: rsaPublicKeyBase64)

        // 1. 组装明文 JSON(timeStamp 为毫秒字符串,实时生成)。
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

        // 2. 依据密钥块大小分块加密并拼接(复刻 encryptLong)。
        let ciphertext = try encryptChunked(plaintext, with: publicKey)

        // 3. 整体 base64。
        return ciphertext.base64EncodedString()
    }

    // MARK: - Private

    /// 导入 base64 PKCS#1 DER 公钥为 `SecKey`。
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
            // 不透传底层 error 细节,避免潜在敏感信息进入上层日志。
            error?.release()
            throw CardEncryptorError.invalidPublicKey
        }
        return key
    }

    /// 按密钥块大小对明文分块,逐块 RSA 加密后拼接成单个 `Data`。
    ///
    /// 单块可容纳的最大明文 = `SecKeyGetBlockSize(key) - 11`(PKCS#1 v1.5 开销)。
    /// 每个密文块长度恒为块大小,拼接结果长度 = 块数 × 块大小,后端可据此精确切分还原。
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
