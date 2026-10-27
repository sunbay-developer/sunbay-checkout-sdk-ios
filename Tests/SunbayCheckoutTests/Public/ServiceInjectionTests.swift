import Foundation
import XCTest

@testable import SunbayCheckout

/// 公共服务注入缝（Task 11.5）的测试（纯逻辑，macOS host 可直接运行，无 UIKit 依赖）。
///
/// 覆盖两条路径：
/// 1. `SunbayCheckout(configuration:paymentService:cofService:)` 注入的 host 服务，
///    确实被 `makeController` 组装进 `CheckoutController` 并驱动到已知结果。
/// 2. 朴素的 `SunbayCheckout(configuration:)` 仍可构造，其控制器 fail-closed：
///    confirm 失败且错误码为 `NETWORK_UNAVAILABLE`（Unconfigured 默认服务）。
final class ServiceInjectionTests: XCTestCase {
    private func makeConfig() -> CheckoutConfiguration {
        CheckoutConfiguration(environment: .test)
    }

    private func makeSession(
        id: String = "sess_inject",
        expiresAt: Date = Date().addingTimeInterval(600)
    ) -> CheckoutSession {
        CheckoutSession(
            id: id,
            amount: Amount(minorUnits: 999, currencyCode: "USD"),
            merchantName: "Acme",
            methods: [.card, .applePay],
            expiresAt: expiresAt,
            rsaPublicKey: nil,
            cofEnabled: true
        )
    }

    // MARK: - 1. 注入的服务被 makeController 使用并驱动到已知结果

    func test_injectedServices_areUsedByController_drivingToSucceeded() async throws {
        let payment = MockPaymentService()
        payment.stubSession(makeSession())
        payment.stubSubmit([PaymentSnapshot(sessionId: "sess_inject", status: .succeeded, txnId: "txn_ok")])
        let cof = MockCofService()

        let checkout = SunbayCheckout(
            configuration: makeConfig(),
            paymentService: payment,
            cofService: cof
        )

        // 经内部缝用「已注入的服务」组装控制器。
        let controller = checkout.makeController(
            credentials: CredentialStore(),
            actionHandler: StubActionHandler()
        )

        _ = try await controller.start(sessionId: "sess_inject", customerAccessSecret: nil)
        let outcome = await controller.confirmSavedCard(paymentMethodId: "pm_1")

        guard case .succeeded(let txnId) = outcome else {
            return XCTFail("注入的 MockPaymentService 应驱动到 .succeeded，实际为 \(outcome)")
        }
        XCTAssertEqual(txnId, "txn_ok")
        XCTAssertEqual(payment.submitCallCount, 1, "应经由注入的 payment service 提交一次")
        XCTAssertEqual(payment.loadSessionCallCount, 1, "应经由注入的 payment service 加载一次会话")
    }

    // MARK: - 2. 朴素 init 仍构造，其控制器 fail-closed（NETWORK_UNAVAILABLE）

    func test_plainInit_controllerFailsClosed_withNetworkUnavailable() async throws {
        let checkout = SunbayCheckout(configuration: makeConfig())

        let controller = checkout.makeController(
            credentials: CredentialStore(),
            actionHandler: StubActionHandler()
        )

        // 朴素 init 下，loadSession 直接抛 NETWORK_UNAVAILABLE（Unconfigured 默认）。
        do {
            _ = try await controller.start(sessionId: "sess_x", customerAccessSecret: nil)
            XCTFail("未配置默认服务应在加载会话时 fail-closed")
        } catch let error as CheckoutError {
            XCTAssertEqual(error.code, "NETWORK_UNAVAILABLE")
        }
    }
}
