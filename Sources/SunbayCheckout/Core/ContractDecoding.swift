import Foundation

/// 查询结果解码产物:快照 + 可选的进一步动作。
///
/// `PaymentSnapshot` 保持 Task 2 定义不变(不加字段);`action` 在 `txnStatus == "R"` 时解析,
/// 供 Task 6/8 按类型分发(见 §4.5)。
struct ResultEnvelope: Sendable, Equatable {
    /// 结果快照。
    let snapshot: PaymentSnapshot
    /// 进一步动作;非 `requiresAction` 或无 `action` 时为 nil。
    let action: PaymentAction?
}

/// 后端契约 JSON → Core 模型的解码助手(内部)。
///
/// 把 product-spec §7.1 的会话 JSON 与 §7.4 的结果 JSON 映射为 `CheckoutSession` /
/// `PaymentSnapshot` / `PaymentAction`。对未知的支付方式与动作类型降级处理,不崩溃。
///
/// - Note: 此处为纯解码逻辑,不触碰网络;真实适配器负责把响应体喂给这些函数。
enum ContractDecoding {
    // MARK: - Session(§7.1)

    /// 会话 JSON 的线格式(仅取 Core 需要的字段;其余字段忽略)。
    private struct SessionWire: Decodable {
        let sessionId: String
        let currency: String
        let totalAmount: Int64
        let expiresAt: String
        let merchantName: String
        let rsaPublicKey: String?
        let cofEnabled: Bool
        let paymentMethods: [PaymentMethodWire]
    }

    /// 单个支付方式条目(§7.1:`method` 例 VISA/APPLE_PAY,`type` 例 CARD/E_WALLET)。
    private struct PaymentMethodWire: Decodable {
        let method: String
        let type: String
    }

    /// 解码会话 JSON 为 `CheckoutSession`。
    ///
    /// - `totalAmount` + `currency` → `Amount(minorUnits:currencyCode:)`(整数最小货币单位)。
    /// - `paymentMethods[].method/type` → `Set<PaymentMethodKind>`;未知方式忽略而非崩溃。
    /// - `expiresAt` 按 ISO-8601 解析。
    ///
    /// - Parameter data: 会话 JSON 数据。
    /// - Returns: 解码后的会话模型。
    /// - Throws: JSON 结构不符或 `expiresAt` 非法 ISO-8601 时抛出 `DecodingError`。
    static func decodeSession(from data: Data) throws -> CheckoutSession {
        let wire = try JSONDecoder().decode(SessionWire.self, from: data)

        guard let expiresAt = parseISO8601(wire.expiresAt) else {
            throw DecodingError.dataCorrupted(
                DecodingError.Context(
                    codingPath: [],
                    debugDescription: "expiresAt 不是合法的 ISO-8601: \(wire.expiresAt)"
                )
            )
        }

        let methods = wire.paymentMethods.reduce(into: Set<PaymentMethodKind>()) { acc, pm in
            if let kind = mapMethod(method: pm.method, type: pm.type) {
                acc.insert(kind)
            }
            // 未知方式:忽略(降级),不崩溃。
        }

        return CheckoutSession(
            id: wire.sessionId,
            amount: Amount(minorUnits: wire.totalAmount, currencyCode: wire.currency),
            merchantName: wire.merchantName,
            methods: methods,
            expiresAt: expiresAt,
            rsaPublicKey: wire.rsaPublicKey,
            cofEnabled: wire.cofEnabled
        )
    }

    /// 把后端 `method`/`type` 映射为 `PaymentMethodKind`。
    ///
    /// 已知卡品牌或 `type == "CARD"` → `.card`;`APPLE_PAY` → `.applePay`;其余返回 nil(忽略)。
    ///
    /// - Note: 会话里下发的可用方式描述的是新卡/钱包;`.savedCard` 的可用性由 `cofEnabled` 与
    ///   列卡结果(§7.5)决定,不从这里的方式条目推导。
    private static func mapMethod(method: String, type: String) -> PaymentMethodKind? {
        switch method.uppercased() {
        case "APPLE_PAY":
            return .applePay
        case "VISA", "MASTERCARD", "AMEX", "CARD":
            return .card
        default:
            // 回退到 type:显式 CARD 也视为新卡。
            return type.uppercased() == "CARD" ? .card : nil
        }
    }

    // MARK: - Result(§7.4)

    /// 结果 JSON 的线格式。
    private struct ResultWire: Decodable {
        let txnId: String?
        let txnStatus: String
        let sessionId: String
        let action: ActionWire?
    }

    /// `action` 对象(§7.4;`txnStatus == "R"` 时携带)。
    private struct ActionWire: Decodable {
        let type: String
        let redirectUrl: String?
    }

    /// 解码结果 JSON 为 `ResultEnvelope`(快照 + 可选动作)。
    ///
    /// `txnStatus` 映射到 `TxnStatus`(I/S/F/R);当 `txnStatus == "R"` 时解析 `action.type`:
    /// `redirect` 且有合法 `redirectUrl` → `.redirect(url:)`,否则 `.unknown`;
    /// `qrCode` → `.qrCode`;`showContent` → `.showContent`;其他 → `.unknown`。
    ///
    /// - Parameter data: 结果 JSON 数据。
    /// - Returns: 解码后的结果信封。
    /// - Throws: JSON 结构不符或 `txnStatus` 非法时抛出 `DecodingError`。
    static func decodeResult(from data: Data) throws -> ResultEnvelope {
        let wire = try JSONDecoder().decode(ResultWire.self, from: data)

        guard let status = TxnStatus(rawValue: wire.txnStatus) else {
            throw DecodingError.dataCorrupted(
                DecodingError.Context(
                    codingPath: [],
                    debugDescription: "未知 txnStatus: \(wire.txnStatus)"
                )
            )
        }

        let snapshot = PaymentSnapshot(
            sessionId: wire.sessionId,
            status: status,
            txnId: wire.txnId
        )

        let action: PaymentAction? = status == .requiresAction ? mapAction(wire.action) : nil
        return ResultEnvelope(snapshot: snapshot, action: action)
    }

    /// 把 `action` 对象映射为 `PaymentAction`;无法识别时降级为 `.unknown`。
    private static func mapAction(_ action: ActionWire?) -> PaymentAction {
        guard let action else { return .unknown }
        switch action.type {
        case "redirect":
            // redirect 需要合法 URL;缺失或非法则无法跳转,降级为 unknown。
            if let raw = action.redirectUrl, let url = URL(string: raw) {
                return .redirect(url: url)
            }
            return .unknown
        case "qrCode":
            return .qrCode
        case "showContent":
            return .showContent
        default:
            return .unknown
        }
    }

    // MARK: - ISO-8601

    /// 解析 ISO-8601 字符串为 `Date`;兼容带/不带小数秒两种写法。
    private static func parseISO8601(_ string: String) -> Date? {
        let withFractional = ISO8601DateFormatter()
        withFractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = withFractional.date(from: string) {
            return date
        }
        let plain = ISO8601DateFormatter()
        plain.formatOptions = [.withInternetDateTime]
        return plain.date(from: string)
    }
}
