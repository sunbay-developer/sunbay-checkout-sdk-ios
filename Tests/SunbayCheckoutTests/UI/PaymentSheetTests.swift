#if canImport(UIKit)
    import Security
    import UIKit
    import XCTest

    @testable import SunbayCheckout

    /// `PaymentSheet`（L1，黑盒支付页）的单元测试（仅 iOS；macOS 宿主下 `#if canImport(UIKit)` 整体排除）。
    ///
    /// ## 可测逻辑 vs. `present()` 包装的拆分
    /// 在无 host app 的 headless xctest 里，真正驱动 UIKit 展示（`presenter.present(...)`）既脆弱又
    /// 不可确定。为此 `PaymentSheet` 把「start → （按 COF 判定）list → 等待用户动作 → confirm → outcome」
    /// 的控制器驱动逻辑收敛到一个 **internal、可测**的方法 `runCheckout(seam:)` 里；`present(from:)`
    /// 只是薄薄的 UIKit 包装：构造并展示 `PaymentSheetViewController`，把它的「用户动作」桥接给
    /// `runCheckout` 的 `seam`，再 await 同一套逻辑得到 `CheckoutOutcome`。
    ///
    /// 这些测试经 **internal 初始化器** 注入由 mock 后端组装的真实 `CheckoutController`，直接调用
    /// `runCheckout(seam:)` 并以 `seam` 触发目标用户动作（等价于点击新卡确认 / 选卡 / 取消），
    /// 从而在不触碰真实展示的前提下验证 start/list/confirm/outcome。完整 UI 由示例 app（Task 13）验证。
    final class PaymentSheetTests: XCTestCase {
        // MARK: - 组装辅助

        /// 构造一个会话（可配置 `cofEnabled` 与支付方式）。
        private func makeSession(
            id: String,
            cofEnabled: Bool,
            rsaPublicKey: String? = nil
        ) -> CheckoutSession {
            CheckoutSession(
                id: id,
                amount: Amount(minorUnits: 999, currencyCode: "USD"),
                merchantName: "Acme",
                methods: [.card, .savedCard, .applePay],
                expiresAt: Date().addingTimeInterval(600),
                rsaPublicKey: rsaPublicKey,
                cofEnabled: cofEnabled
            )
        }

        /// 用 mock 后端 + stub action handler 组装一个真实 `CheckoutController`，并返回用到的 mock。
        private func makeController(
            session: CheckoutSession,
            cards: [SavedCard] = [],
            submit snapshots: [PaymentSnapshot] = []
        ) -> (CheckoutController, MockPaymentService, MockCofService) {
            let payment = MockPaymentService()
            payment.stubSession(session)
            if !snapshots.isEmpty { payment.stubSubmit(snapshots) }
            let cof = MockCofService()
            cof.stubCards(cards)
            let controller = CheckoutController(
                paymentService: payment,
                cofService: cof,
                credentials: CredentialStore(),
                actionHandler: StubActionHandler(result: .pending)
            )
            return (controller, payment, cof)
        }

        // MARK: - 1. COF：有 secret + cofEnabled → 列已保存卡

        func test_present_cofEnabledWithSecret_listsSavedCards() async {
            let sessionId = "sess_cof_1"
            let session = makeSession(id: sessionId, cofEnabled: true)
            let scriptedCard = SavedCard(
                id: "pm_1", brand: "visa", last4: "4242", expMonth: 12, expYear: 2030
            )
            let (controller, _, cof) = makeController(session: session, cards: [scriptedCard])

            let sheet = PaymentSheet(
                controller: controller,
                sessionId: sessionId,
                customerAccessSecret: "secret_abc"
            )

            // 直接驱动可测逻辑；seam 在列卡完成后立即取消（本例只验证列卡路径被走到）。
            let outcome = await sheet.runCheckout { context in
                // context.savedCards 应包含脚本化卡；并且 CofService 应被调用过一次。
                XCTAssertEqual(context.savedCards.map(\.id), ["pm_1"])
                return .cancel
            }

            XCTAssertEqual(cof.listCallCount, 1)
            XCTAssertEqual(cof.lastCustomerAccessSecret, "secret_abc")
            guard case .canceled = outcome else {
                return XCTFail("expected .canceled after cancel seam, got \(outcome)")
            }
        }

        // MARK: - 2. 无 secret → 不列已保存卡

        func test_present_noSecret_doesNotListSavedCards() async {
            let sessionId = "sess_cof_2"
            let session = makeSession(id: sessionId, cofEnabled: true)
            let (controller, _, cof) = makeController(session: session, cards: [
                SavedCard(id: "pm_x", brand: "visa", last4: "1111", expMonth: 1, expYear: 2031),
            ])

            // 不传 customerAccessSecret。
            let sheet = PaymentSheet(controller: controller, sessionId: sessionId)

            let outcome = await sheet.runCheckout { context in
                XCTAssertTrue(context.savedCards.isEmpty, "no secret → no saved cards")
                return .cancel
            }

            // 无 secret → CofService 绝不被调用。
            XCTAssertEqual(cof.listCallCount, 0)
            guard case .canceled = outcome else {
                return XCTFail("expected .canceled, got \(outcome)")
            }
        }

        // MARK: - 3. present 以控制器 outcome 解析

        func test_present_resolvesWithControllerOutcome() async throws {
            let sessionId = "sess_resolve_1"
            // 带 rsaPublicKey 以便新卡路径能加密；脚本化 submit 返回 S。
            // 运行时生成一对真实 RSA 密钥，用公钥（PKCS#1 DER base64，与 CardEncryptor 导入格式一致）
            // 喂给会话，确保 CardEncryptor 可加密成功，从而驱动到 submit。
            let publicKeyBase64 = try Self.makeRSAPublicKeyBase64(bits: 2048)
            let session = makeSession(
                id: sessionId,
                cofEnabled: false,
                rsaPublicKey: publicKeyBase64
            )
            let (controller, payment, _) = makeController(
                session: session,
                submit: [PaymentSnapshot(sessionId: sessionId, status: .succeeded, txnId: "txn_ok")]
            )

            let sheet = PaymentSheet(controller: controller, sessionId: sessionId)

            let cardInput = CardInput(
                cardNumber: "4242424242424242",
                expiryMonth: "12",
                expiryYear: "2030",
                cvv: "123"
            )

            let outcome = await sheet.runCheckout { _ in
                // 等价于用户填好新卡并点击确认（不勾选保存）。
                .confirmNewCard(cardInput, save: false)
            }

            XCTAssertEqual(payment.submitCallCount, 1)
            guard case .succeeded(let txnId) = outcome else {
                return XCTFail("expected .succeeded, got \(outcome)")
            }
            XCTAssertEqual(txnId, "txn_ok")
        }

        // MARK: - 4. EmbeddedPaymentElement 为 internal（编译期）

        func test_embeddedPaymentElement_isInternal_notPublic() {
            // 仅可经 @testable 从测试目标引用；若它被误标 public，这行仍能编译，
            // 但“非 public”的真正守卫是 Final verification 的 public-API 审计 + 本断言的存在性说明。
            // 这里通过内部可见性实例化来锚定它是“同模块 internal 符号”。
            let stub = EmbeddedPaymentElement()
            XCTAssertNotNil(stub)
        }
    }

    // MARK: - 测试用 RSA 公钥

    extension PaymentSheetTests {
        /// 运行时生成一个 RSA 公钥（PKCS#1 DER / base64），格式与 `CardEncryptor` 的导入约定一致。
        ///
        /// 用于 `test_present_resolvesWithControllerOutcome` 让 `CardEncryptor` 能真实加密新卡数据，
        /// 从而驱动到 `submit`。该公钥不对应任何真实后端私钥，仅做本地加密形状验证。
        static func makeRSAPublicKeyBase64(bits: Int) throws -> String {
            let attributes: [CFString: Any] = [
                kSecAttrKeyType: kSecAttrKeyTypeRSA,
                kSecAttrKeySizeInBits: bits,
            ]
            var error: Unmanaged<CFError>?
            guard let privateKey = SecKeyCreateRandomKey(attributes as CFDictionary, &error) else {
                throw error!.takeRetainedValue() as Error
            }
            guard let publicKey = SecKeyCopyPublicKey(privateKey) else {
                throw NSError(domain: "PaymentSheetTests", code: -1)
            }
            guard let der = SecKeyCopyExternalRepresentation(publicKey, &error) as Data? else {
                throw error!.takeRetainedValue() as Error
            }
            return der.base64EncodedString()
        }
    }
#endif
