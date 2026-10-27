import Foundation
import SunbayCheckout

// MARK: - 脚本化结果(demo 用)

/// 本次 demo 想让 `submit` 落到的终态/中间态脚本。
///
/// 让 demo 一键切换四种 `CheckoutOutcome`(succeeded / failed / pending / unknown)
/// 以及 `requiresAction`,全部打在 mock 后端里,UI 不需要任何业务分支。
public enum DemoScript: Sendable {
    /// 提交即成功(终态 S)。
    case succeeded
    /// 提交即失败(终态 F)。
    case failed
    /// 处理中(非终态 I)——UI 呈现 pending。
    case pending
    /// 需要进一步动作(R)。
    case requiresAction
    /// 提交超时/网络不可用——Core 进入 unknown,随后可用 `getResult` 恢复。
    case networkTimeout
}

/// demo 脚本抛出的"网络不可用"错误(仅 `networkTimeout` 用)。
///
/// 真实后端的网络失败由适配器抛出;这里用一个最小的 Error 模拟 submit 超时,
/// 让 `CheckoutController` 走 unknown 分支(§3.2:提交超时不盲重试,先 getResult)。
private struct DemoNetworkUnavailable: Error {}

// MARK: - 内存 Mock PaymentService

/// demo 用的内存 `PaymentService`,实现 SDK 公共协议(Task 11.5 注入缝)。
///
/// - `loadSession` 返回脚本化会话:带 demo RSA **公钥**(PKCS#1 DER base64,
///   让 `CardEncryptor` 能正常导入加密)、`cofEnabled = true`、方式
///   `[.card, .applePay, .savedCard]`、一笔金额与商户名。
/// - `submit` 按 `script` 返回脚本化快照(默认成功);`networkTimeout` 抛错让 Core 进 unknown。
/// - `getResult` 始终返回一个终态快照(供 unknown 恢复 demo)。
///
/// 全内存、无真实后端、无任何机密。线程安全:字段只读或在构造时固定,`script` 可变但
/// demo 在单线程(主线程点击)驱动;标注 `@unchecked Sendable` 以满足协议的 `Sendable`。
public final class MockDemoPaymentService: PaymentService, @unchecked Sendable {
    /// 本次要演示的脚本(可在 demo UI 切换)。
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
            expiresAt: Date().addingTimeInterval(15 * 60), // 15 分钟后过期
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
            // 模拟 submit 超时/网络不可用 → Core 进入 unknown(不盲重试),随后 getResult 恢复。
            throw DemoNetworkUnavailable()
        }
    }

    public func getResult(sessionId: String) async throws -> PaymentSnapshot {
        // 恢复 demo:无论先前脚本如何,查询都给出一个已确认的终态(成功)。
        PaymentSnapshot(sessionId: sessionId, status: .succeeded, txnId: "demo_txn_recovered")
    }
}

// MARK: - 内存 Mock CofService

/// demo 用的内存 `CofService`,返回 1-2 张脚本化已保存卡(COF 一键付演示)。
public final class MockDemoCofService: CofService, @unchecked Sendable {
    public init() {}

    public func listPaymentMethods(customerAccessSecret: String, sessionId: String) async throws -> [SavedCard] {
        [
            SavedCard(id: "pm_demo_visa", brand: "visa", last4: "4242", expMonth: 12, expYear: 2029),
            SavedCard(id: "pm_demo_mc", brand: "mastercard", last4: "4444", expMonth: 8, expYear: 2028),
        ]
    }
}

// MARK: - Demo RSA 公钥(一次性、可提交的演示用公钥)

/// 一次性生成的 **demo RSA 公钥**(PKCS#1 `RSAPublicKey` DER,base64)。
///
/// - 这是 **公钥**(非密钥),专为本 demo 一次性生成、可随源码提交(见 AGENTS.md:公钥非机密)。
///   对应的私钥**未提交**且已丢弃——没有任何真实后端能用它解密,纯粹让 `CardEncryptor`
///   在 demo 中成功导入并加密(产出一段合法 base64 密文交给 mock 后端)。
/// - 格式与 `CardEncryptor` 的导入约定一致:`SecKeyCreateWithData`(kSecAttrKeyTypeRSA +
///   kSecAttrKeyClassPublic)可直接导入的 PKCS#1 DER。2048-bit(blockSize 256)。
/// - **切勿**在真实集成中使用此 key;真实公钥由后端经 session 下发。
public enum DemoRSAKey {
    /// demo 公钥,PKCS#1 DER 的 base64(单行)。
    public static let publicKeyPKCS1Base64 =
        "MIIBCgKCAQEAt65MyjQltDrA/Pl56ZlI9lMkXPB8dqbvrvbCljmZHUPHSDrp0fh4wxjA4iXkzI3OblbiXUZUEVmj+Htwqo9bSeVRXj3jD4HUgIPx13kyVqSifvH+EdCCL3q/+dWVqG+A/JtXrT/r2gtx0qG/d4WStLt6wn7BCwhL+JKs5ngJlQQbmQhajTukzLhY6pXiQKscw0LOWhxYa+y+xk5ILubcKbsDPP5MD12b1avQdc3IeygPRSEz5zBxLVEMgtJLRsfWcjbWpcsXiZQry8GnjjsOlpxPTVd7+fOnAIoHWDbunPktiXK+WcgGG2B4R26JxpP4UUjaUtpLFjLak/UwSt8HjQIDAQAB"
}
