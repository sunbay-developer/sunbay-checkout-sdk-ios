import Foundation
import Security
import XCTest

@testable import SunbayCheckout

/// `CheckoutController` 的编排 / 状态机 / 不变量测试(Task 6 Step 1)。
///
/// 覆盖 product-spec §4.2 的并发与幂等不变量:单活跃会话、一次点击一个 attemptId、
/// 提交失败先查询不盲目重发、结果去重、终态即清凭证;以及三条路径的 submit 字段差异。
final class CheckoutControllerTests: XCTestCase {
    // MARK: - Fixtures

    /// 构造一个未过期、可用新卡/钱包、可选 COF 的会话。
    private func makeSession(
        id: String = "sess_1",
        cofEnabled: Bool = true,
        rsaPublicKey: String? = nil,
        expiresAt: Date = Date().addingTimeInterval(600)
    ) -> CheckoutSession {
        CheckoutSession(
            id: id,
            amount: Amount(minorUnits: 999, currencyCode: "USD"),
            merchantName: "Acme",
            methods: [.card, .applePay],
            expiresAt: expiresAt,
            rsaPublicKey: rsaPublicKey,
            cofEnabled: cofEnabled
        )
    }

    private func terminalSucceeded(
        sessionId: String = "sess_1",
        txnId: String = "txn_1"
    ) -> PaymentSnapshot {
        PaymentSnapshot(sessionId: sessionId, status: .succeeded, txnId: txnId)
    }

    private func makeController(
        payment: MockPaymentService,
        cof: MockCofService = MockCofService(),
        credentials: CredentialStore = CredentialStore(),
        actionHandler: StubActionHandler = StubActionHandler(),
        poller: ResultPoller? = nil
    ) -> CheckoutController {
        CheckoutController(
            paymentService: payment,
            cofService: cof,
            credentials: credentials,
            actionHandler: actionHandler,
            poller: poller
        )
    }

    /// 构造一个以注入 payment 为后端、且注入「零等待」sleep 的 poller,
    /// 让控制器在 `.initial`(pending)时能确定性、无真实休眠地轮询到终态。
    private func noWaitPoller(payment: MockPaymentService) -> ResultPoller {
        ResultPoller(
            service: payment,
            config: PollConfig(initial: 0.001, max: 0.001, overallLimit: 0.05),
            sleep: { _ in }
        )
    }

    private func newCardInput() -> CardInput {
        CardInput(cardNumber: "4242424242424242", expiryMonth: "12", expiryYear: "2029", cvv: "123")
    }

    /// 生成 2048 位 RSA 公钥(PKCS#1 DER 的 base64),让 `CardEncryptor` 真正能加密。
    private func makeRSAPublicKey() throws -> String {
        let attributes: [String: Any] = [
            kSecAttrKeyType as String: kSecAttrKeyTypeRSA,
            kSecAttrKeySizeInBits as String: 2048,
        ]
        var error: Unmanaged<CFError>?
        guard let priv = SecKeyCreateRandomKey(attributes as CFDictionary, &error) else {
            throw error!.takeRetainedValue() as Error
        }
        guard let pub = SecKeyCopyPublicKey(priv),
              let der = SecKeyCopyExternalRepresentation(pub, &error) as Data?
        else {
            throw NSError(domain: "CheckoutControllerTests", code: -1)
        }
        return der.base64EncodedString()
    }

    // MARK: - 不变量:单活跃会话

    func test_singleActiveSession_secondConfirmReturnsAlreadyPresenting() async throws {
        let payment = MockPaymentService()
        payment.stubSession(makeSession())
        payment.stubSubmit([terminalSucceeded()])
        payment.stubSubmitDelay(.milliseconds(300)) // 让第一次 confirm 处于在途状态

        let controller = makeController(payment: payment)
        _ = try await controller.start(sessionId: "sess_1", customerAccessSecret: nil)

        async let first = controller.confirmSavedCard(paymentMethodId: "pm_1")
        // 给第一次 confirm 一点时间进入在途(占住活跃锁)。
        try await Task.sleep(for: .milliseconds(50))
        async let second = controller.confirmSavedCard(paymentMethodId: "pm_2")

        let (r1, r2) = await (first, second)

        // 恰有一个成功、一个 alreadyPresenting。
        let outcomes = [r1, r2]
        let succeededCount = outcomes.filter { if case .succeeded = $0 { return true }; return false }.count
        let presentingCount = outcomes.filter {
            if case .failed(_, let err) = $0 { return err.code == "ALREADY_PRESENTING" }
            return false
        }.count

        XCTAssertEqual(succeededCount, 1, "应恰有一次成功")
        XCTAssertEqual(presentingCount, 1, "第二次并发 confirm 应返回 alreadyPresenting")
        XCTAssertEqual(payment.submitCallCount, 1, "第二次 confirm 不得再次 submit")
    }

    // MARK: - 不变量:提交失败先查询,绝不盲目重发

    func test_submitTimeout_queriesResult_neverResubmits() async throws {
        let payment = MockPaymentService()
        payment.stubSession(makeSession())
        payment.stubSubmitError(URLError(.timedOut))
        payment.stubGetResult([terminalSucceeded(txnId: "txn_query")])

        let controller = makeController(payment: payment)
        _ = try await controller.start(sessionId: "sess_1", customerAccessSecret: nil)

        let outcome = await controller.confirmSavedCard(paymentMethodId: "pm_1")

        XCTAssertEqual(payment.submitCallCount, 1, "submit 只应发生一次")
        XCTAssertEqual(payment.getResultCallCount, 1, "submit 失败后应查询一次")
        if case .succeeded(let txnId) = outcome {
            XCTAssertEqual(txnId, "txn_query", "应映射 getResult 的快照")
        } else {
            XCTFail("应映射 getResult 返回的成功快照,实际:\(outcome)")
        }
    }

    func test_submitFails_andGetResultFails_mapsToUnknown() async throws {
        let payment = MockPaymentService()
        payment.stubSession(makeSession())
        payment.stubSubmitError(URLError(.timedOut))
        payment.stubGetResultError(URLError(.notConnectedToInternet))

        let controller = makeController(payment: payment)
        _ = try await controller.start(sessionId: "sess_1", customerAccessSecret: nil)

        let outcome = await controller.confirmSavedCard(paymentMethodId: "pm_1")

        XCTAssertEqual(payment.submitCallCount, 1)
        XCTAssertEqual(payment.getResultCallCount, 1)
        if case .unknown(let sessionId) = outcome {
            XCTAssertEqual(sessionId, "sess_1")
        } else {
            XCTFail("submit 与 getResult 都失败应映射 unknown,实际:\(outcome)")
        }
    }

    // MARK: - 不变量:结果去重(终态只交付一次)

    func test_duplicateTerminalResult_deliveredOnce() async throws {
        let payment = MockPaymentService()
        payment.stubSession(makeSession())
        // 为同一次尝试脚本化两个相同的终态快照;一次 confirm 只消费一个并交付一次。
        payment.stubSubmit([terminalSucceeded(), terminalSucceeded()])

        let controller = makeController(payment: payment)
        _ = try await controller.start(sessionId: "sess_1", customerAccessSecret: nil)

        let outcome = await controller.confirmSavedCard(paymentMethodId: "pm_1")

        XCTAssertEqual(payment.submitCallCount, 1, "一次 confirm 只 submit 一次")
        if case .succeeded = outcome {} else {
            XCTFail("应交付一次成功,实际:\(outcome)")
        }
        // 活跃锁应已释放:再次 confirm 不会被 alreadyPresenting 挡住。
        let again = await controller.confirmSavedCard(paymentMethodId: "pm_1")
        if case .failed(_, let err) = again, err.code == "ALREADY_PRESENTING" {
            XCTFail("终态后活跃锁应已释放")
        }
    }

    // MARK: - 新卡:加密并提交

    func test_newCard_encryptsAndSubmits() async throws {
        let rsaKey = try makeRSAPublicKey()
        let payment = MockPaymentService()
        payment.stubSession(makeSession(rsaPublicKey: rsaKey))
        payment.stubSubmit([terminalSucceeded()])

        let controller = makeController(payment: payment)
        _ = try await controller.start(sessionId: "sess_1", customerAccessSecret: nil)

        _ = await controller.confirmNewCard(newCardInput(), save: false, consent: nil)

        let req = try XCTUnwrap(payment.lastSubmitRequest)
        XCTAssertNotNil(req.cardEncryptedData)
        XCTAssertFalse(req.cardEncryptedData?.isEmpty ?? true, "新卡应携带非空密文")
        XCTAssertNil(req.paymentMethodId, "新卡不得携带 paymentMethodId")
        XCTAssertNil(req.walletToken)
    }

    // MARK: - 已保存卡:只带 paymentMethodId,不带卡数据

    func test_savedCard_submitsPaymentMethodId_noCardData() async throws {
        let payment = MockPaymentService()
        payment.stubSession(makeSession())
        payment.stubSubmit([terminalSucceeded()])

        let controller = makeController(payment: payment)
        _ = try await controller.start(sessionId: "sess_1", customerAccessSecret: nil)

        _ = await controller.confirmSavedCard(paymentMethodId: "pm_42")

        let req = try XCTUnwrap(payment.lastSubmitRequest)
        XCTAssertEqual(req.paymentMethodId, "pm_42")
        XCTAssertNil(req.cardEncryptedData, "已保存卡不得携带卡密文")
        XCTAssertNil(req.walletToken)
    }

    // MARK: - COF 关闭:列卡为空且不调用 CofService

    func test_cofDisabled_listSavedCardsEmpty() async throws {
        let payment = MockPaymentService()
        payment.stubSession(makeSession(cofEnabled: false))
        let cof = MockCofService()
        cof.stubCards([SavedCard(id: "pm_1", brand: "visa", last4: "4242", expMonth: 12, expYear: 2029)])

        let controller = makeController(payment: payment, cof: cof)
        _ = try await controller.start(sessionId: "sess_1", customerAccessSecret: "secret_abc")

        let cards = await controller.listSavedCards()

        XCTAssertTrue(cards.isEmpty, "COF 关闭应返回空列表")
        XCTAssertEqual(cof.listCallCount, 0, "COF 关闭时绝不调用 CofService")
    }

    func test_cofListThrows_degradesToEmpty() async throws {
        let payment = MockPaymentService()
        payment.stubSession(makeSession(cofEnabled: true))
        let cof = MockCofService()
        cof.stubError(URLError(.badServerResponse))

        let controller = makeController(payment: payment, cof: cof)
        _ = try await controller.start(sessionId: "sess_1", customerAccessSecret: "secret_abc")

        let cards = await controller.listSavedCards()

        XCTAssertTrue(cards.isEmpty, "列卡失败应降级为空,不抛出")
        XCTAssertEqual(cof.listCallCount, 1)
    }

    // MARK: - 终态即清凭证

    func test_terminalState_clearsCredentials() async throws {
        let payment = MockPaymentService()
        payment.stubSession(makeSession())
        payment.stubSubmit([terminalSucceeded()])
        let credentials = CredentialStore()

        let controller = makeController(payment: payment, credentials: credentials)
        _ = try await controller.start(sessionId: "sess_1", customerAccessSecret: "secret_abc")

        await credentials.hold(customerAccessSecret: "secret_abc")
        let before = await credentials.current()
        XCTAssertNotNil(before)

        _ = await controller.confirmSavedCard(paymentMethodId: "pm_1")

        let held = await credentials.current()
        XCTAssertNil(held, "终态后应已清除凭证")
    }

    // MARK: - start:过期会话应抛出

    func test_start_expiredSession_throws() async throws {
        let payment = MockPaymentService()
        payment.stubSession(makeSession(expiresAt: Date().addingTimeInterval(-10)))

        let controller = makeController(payment: payment)

        do {
            _ = try await controller.start(sessionId: "sess_1", customerAccessSecret: nil)
            XCTFail("过期会话应抛出")
        } catch let error as CheckoutError {
            XCTAssertEqual(error.category, .validation)
        }
    }

    // MARK: - requiresAction(R)→ 委派 ActionHandler

    func test_requiresAction_delegatesToActionHandler_pending() async throws {
        let payment = MockPaymentService()
        payment.stubSession(makeSession())
        payment.stubSubmit([PaymentSnapshot(sessionId: "sess_1", status: .requiresAction, txnId: "txn_r")])
        payment.stubNextAction(.redirect(url: URL(string: "https://psp.example/redirect")!))
        let action = StubActionHandler(result: .pending)

        let controller = makeController(payment: payment, actionHandler: action)
        _ = try await controller.start(sessionId: "sess_1", customerAccessSecret: nil)

        let outcome = await controller.confirmSavedCard(paymentMethodId: "pm_1")

        XCTAssertEqual(action.handleCallCount, 1)
        XCTAssertEqual(action.lastAction, .redirect(url: URL(string: "https://psp.example/redirect")!))
        if case .pending(let txnId) = outcome {
            XCTAssertEqual(txnId, "txn_r")
        } else {
            XCTFail("R + 处理器 .pending 应映射 pending,实际:\(outcome)")
        }
    }

    func test_requiresAction_actionHandlerFailed_mapsFailed() async throws {
        let payment = MockPaymentService()
        payment.stubSession(makeSession())
        payment.stubSubmit([PaymentSnapshot(sessionId: "sess_1", status: .requiresAction, txnId: "txn_r")])
        payment.stubNextAction(.qrCode)
        let failErr = CheckoutError(code: "UNSUPPORTED_CAPABILITY", message: "x", category: .runtime, traceId: nil)
        let action = StubActionHandler(result: .failed(failErr))

        let controller = makeController(payment: payment, actionHandler: action)
        _ = try await controller.start(sessionId: "sess_1", customerAccessSecret: nil)

        let outcome = await controller.confirmSavedCard(paymentMethodId: "pm_1")

        if case .failed(let txnId, let err) = outcome {
            XCTAssertEqual(txnId, "txn_r")
            XCTAssertEqual(err.code, "UNSUPPORTED_CAPABILITY")
        } else {
            XCTFail("R + 处理器 .failed 应映射 failed,实际:\(outcome)")
        }
    }

    // MARK: - 两源单次交付去重(Task 6 review 遗留项,Task 7 真正落地)

    /// submit 返回 `.initial`(pending)→ 控制器用 poller 轮询到 `.succeeded`。
    ///
    /// 这取代了 Task 6 里「两个相同终态快照只交付一次」的平凡断言:现在存在**两个真实结果来源**
    /// (submit→pending、poll→terminal),验证确认调用**恰好一次**解析为终态、且解析后**单活跃锁已释放**
    /// (后续 confirm 能再次开始)——这才是真正的双源单次交付检查。
    func test_pendingThenPolledTerminal_deliversSingleOutcome() async throws {
        let payment = MockPaymentService()
        payment.stubSession(makeSession())
        // submit 先返回非终态 I;随后 getResult(轮询)依次 I, S。
        payment.stubSubmit([PaymentSnapshot(sessionId: "sess_1", status: .initial, txnId: "txn_p")])
        payment.stubGetResult([
            PaymentSnapshot(sessionId: "sess_1", status: .initial, txnId: "txn_p"),
            PaymentSnapshot(sessionId: "sess_1", status: .succeeded, txnId: "txn_done"),
        ])

        let controller = makeController(payment: payment, poller: noWaitPoller(payment: payment))
        _ = try await controller.start(sessionId: "sess_1", customerAccessSecret: nil)

        let outcome = await controller.confirmSavedCard(paymentMethodId: "pm_1")

        // 恰好一次解析为 succeeded(轮询拿到的终态)。
        if case .succeeded(let txnId) = outcome {
            XCTAssertEqual(txnId, "txn_done", "应交付轮询得到的终态 txnId")
        } else {
            XCTFail("pending→轮询终态应交付一次 succeeded,实际:\(outcome)")
        }
        XCTAssertEqual(payment.submitCallCount, 1, "一次 confirm 只 submit 一次")

        // 单活跃锁解析后应已释放:后续 confirm 不被 alreadyPresenting 挡住(能再次开始)。
        payment.stubSubmit([terminalSucceeded()])
        let again = await controller.confirmSavedCard(paymentMethodId: "pm_2")
        if case .failed(_, let err) = again, err.code == "ALREADY_PRESENTING" {
            XCTFail("终态解析后单活跃锁应已释放,后续 confirm 应能开始")
        }
    }

    // MARK: - dismiss 清理

    func test_dismiss_clearsCredentials() async throws {
        let payment = MockPaymentService()
        payment.stubSession(makeSession())
        let credentials = CredentialStore()

        let controller = makeController(payment: payment, credentials: credentials)
        _ = try await controller.start(sessionId: "sess_1", customerAccessSecret: "secret_abc")
        await credentials.hold(customerAccessSecret: "secret_abc")

        await controller.dismiss()

        let held = await credentials.current()
        XCTAssertNil(held, "dismiss 应清除凭证")
    }
}
