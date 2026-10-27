#if canImport(UIKit)
    import UIKit
    import XCTest

    @testable import SunbayCheckout

    /// `ApplePayButton`（L3）的单元测试（仅 iOS；macOS 宿主下 `#if canImport(UIKit)` 整体排除）。
    ///
    /// 通过 **internal 初始化器** 注入 mock 控制器（基于现有 `MockPaymentService` /
    /// `MockCofService` / `StubActionHandler` 组装的真实 `CheckoutController`）与 mock
    /// `WalletAuthorizing`，以在无真机 / 无 PassKit 展示的情况下验证：
    /// 1. 可用钱包 → `isAvailable == true` 且触发 `onAvailabilityChange(true)`；
    /// 2. 点击 → 驱动 `onResult` 得到脚本化 outcome（此处 `.succeeded`）。
    ///
    /// 钱包授权成功 ≠ 交易成功；本测试里脚本化后端返回 `S` 使 outcome 为 `.succeeded`。
    final class ApplePayButtonTests: XCTestCase {
        // MARK: - 组装辅助

        /// 一个可用的 Apple Pay 会话（后端允许 `.applePay`、未过期）。
        private func availableSession(id: String) -> CheckoutSession {
            CheckoutSession(
                id: id,
                amount: Amount(minorUnits: 999, currencyCode: "USD"),
                merchantName: "Acme",
                methods: [.applePay, .card],
                expiresAt: Date().addingTimeInterval(600),
                rsaPublicKey: nil,
                cofEnabled: false
            )
        }

        /// 用 mock 后端 + stub action handler 组装一个真实 `CheckoutController`。
        private func makeController(
            session: CheckoutSession,
            submit snapshot: PaymentSnapshot
        ) -> CheckoutController {
            let payment = MockPaymentService()
            payment.stubSession(session)
            payment.stubSubmit([snapshot])
            let cof = MockCofService()
            return CheckoutController(
                paymentService: payment,
                cofService: cof,
                credentials: CredentialStore(),
                actionHandler: StubActionHandler(result: .pending)
            )
        }

        // MARK: - 1. 可用性

        func test_construct_withAvailableWallet_isAvailableTrue_andFiresCallback() {
            let sessionId = "sess_apple_1"
            let session = availableSession(id: sessionId)
            let controller = makeController(
                session: session,
                submit: PaymentSnapshot(sessionId: sessionId, status: .succeeded, txnId: "txn_1")
            )
            let wallet = MockWalletAuthorizer(canMake: true, outcome: .success(Data([0x01])))

            let changeExpectation = expectation(description: "onAvailabilityChange(true)")
            var observed: [Bool] = []

            let button = ApplePayButton(
                controller: controller,
                walletAuthorizer: wallet,
                sessionId: sessionId,
                configuredMerchantId: "merchant.com.acme",
                amount: session.amount
            )
            button.onAvailabilityChange = { available in
                observed.append(available)
                if available { changeExpectation.fulfill() }
            }

            wait(for: [changeExpectation], timeout: 2.0)
            XCTAssertTrue(button.isAvailable)
            XCTAssertEqual(observed.last, true)
        }

        // MARK: - 2. 点击驱动结果

        func test_tap_drivesOnResult_withScriptedOutcome() {
            let sessionId = "sess_apple_2"
            let session = availableSession(id: sessionId)
            let controller = makeController(
                session: session,
                submit: PaymentSnapshot(sessionId: sessionId, status: .succeeded, txnId: "txn_ok")
            )
            let wallet = MockWalletAuthorizer(canMake: true, outcome: .success(Data([0xAB, 0xCD])))

            // 先等待可用性就绪，避免在 session 加载前点击。
            let availableExpectation = expectation(description: "available")
            let resultExpectation = expectation(description: "onResult")
            var received: CheckoutOutcome?

            let button = ApplePayButton(
                controller: controller,
                walletAuthorizer: wallet,
                sessionId: sessionId,
                configuredMerchantId: "merchant.com.acme",
                amount: session.amount
            )
            button.onAvailabilityChange = { available in
                if available { availableExpectation.fulfill() }
            }
            button.onResult = { outcome in
                received = outcome
                resultExpectation.fulfill()
            }

            wait(for: [availableExpectation], timeout: 2.0)
            // 无 host app 的 xctest 运行里 `UIApplication` 为 nil，`sendActions(for:)`
            // 无法把控件事件派发到 target；故直接按 target-action 注册表手动触发 `.touchUpInside`，
            // 等价于一次点击而不依赖 UIApplication 分发。
            fireTouchUpInside(on: button)

            wait(for: [resultExpectation], timeout: 2.0)
            guard case .succeeded(let txnId)? = received else {
                return XCTFail("expected .succeeded, got \(String(describing: received))")
            }
            XCTAssertEqual(txnId, "txn_ok")
        }

        // MARK: - 手动触发控件事件（无 host app 环境）

        /// 直接依据控件的 target-action 注册表触发 `.touchUpInside`。
        ///
        /// 在没有 host app 的 xctest 进程里 `UIApplication.shared` 为 nil，`sendActions`
        /// 不会派发；此法读取控件自己登记的 target/action 并直接调用，等价于一次点击。
        private func fireTouchUpInside(on control: UIControl) {
            for target in control.allTargets {
                let actions = control.actions(forTarget: target, forControlEvent: .touchUpInside) ?? []
                for action in actions {
                    (target as NSObject).perform(Selector(action), with: control)
                }
            }
        }
    }

    // MARK: - Mock WalletAuthorizing

    /// 可脚本化的 `WalletAuthorizing` 替身：设备能力与授权结果均可脚本化。
    /// 授权返回的 token `Data` 仅用于喂给 `confirmWallet`，绝不出现在结果/日志（§5）。
    final class MockWalletAuthorizer: WalletAuthorizing, @unchecked Sendable {
        enum Outcome {
            case success(Data)
            case failure(Error)
        }

        private let canMake: Bool
        private let outcome: Outcome

        init(canMake: Bool, outcome: Outcome) {
            self.canMake = canMake
            self.outcome = outcome
        }

        func canMakePayments() -> Bool { canMake }

        func authorize(amount: Amount, merchantId: String) async throws -> Data {
            switch outcome {
            case .success(let data): return data
            case .failure(let error): throw error
            }
        }
    }
#endif
