import Foundation
import SunbayCheckout

#if canImport(UIKit) && canImport(SwiftUI)
    import SwiftUI
    import UIKit

    // MARK: - App 入口

    /// SunbayCheckout mock 示例 App(SwiftUI,iOS 模拟器)。
    ///
    /// 只消费 SDK **公共** API:`SunbayCheckout(configuration:paymentService:cofService:)`
    /// 注入内存 mock 后端,再用 `PaymentSheet` / `ApplePayButton` 跑通端到端。
    /// 不导入任何内部类型、不使用 @testable。
    @main
    struct SunbayCheckoutDemoApp: App {
        var body: some Scene {
            WindowGroup {
                DemoRootView()
            }
        }
    }

    // MARK: - 根视图

    /// demo 主屏:脚本选择 + "Pay (sheet)" + 独立 ApplePayButton + 结果显示。
    struct DemoRootView: View {
        /// 可切换的 submit 脚本(驱动四种结局 + requiresAction)。
        @State private var script: DemoScript = .succeeded
        /// 最近一次结账结果的可读描述。
        @State private var lastOutcome: String = "—"
        /// 独立 ApplePayButton 的可用性(onAvailabilityChange 驱动显隐)。
        @State private var applePayAvailable = false

        // 固定的 demo 会话标识与 COF 凭证(mock,非机密)。
        private let sessionId = "demo_session_001"
        private let customerAccessSecret = "demo_secret"

        /// mock 支付服务(持有当前脚本);每次切换脚本都同步给它。
        @State private var paymentService = MockDemoPaymentService(script: .succeeded)
        private let cofService = MockDemoCofService()

        var body: some View {
            NavigationView {
                Form {
                    Section("Scenario (mock submit result)") {
                        Picker("Script", selection: $script) {
                            Text("Succeeded").tag(DemoScript.succeeded)
                            Text("Failed").tag(DemoScript.failed)
                            Text("Pending").tag(DemoScript.pending)
                            Text("Requires action").tag(DemoScript.requiresAction)
                            Text("Network timeout → unknown").tag(DemoScript.networkTimeout)
                        }
                        .pickerStyle(.menu)
                        .onChange(of: script) { newValue in
                            paymentService.script = newValue
                        }
                    }

                    Section("PaymentSheet (L1 black-box)") {
                        Text("Presents the SDK sheet: new-card form, 'Save this card', the two mock saved cards (COF one-tap), and an Apple Pay entry row.")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                        PaySheetButton(
                            checkout: makeCheckout(),
                            sessionId: sessionId,
                            customerAccessSecret: customerAccessSecret,
                            onOutcome: { lastOutcome = describe($0) }
                        )
                    }

                    Section("Standalone ApplePayButton (L3)") {
                        Text(applePayAvailable
                            ? "Available — tap to drive the wallet authorization end-to-end (confirmWallet)."
                            : "Hidden/unavailable (device cannot make payments, or merchant-id not configured).")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                        ApplePayButtonView(
                            checkout: makeCheckout(),
                            sessionId: sessionId,
                            onResult: { lastOutcome = describe($0) },
                            onAvailabilityChange: { applePayAvailable = $0 }
                        )
                        .frame(height: 48)
                        // 不可用时仍渲染(内部 isEnabled=false);可用性用文案提示。
                    }

                    Section("Last outcome") {
                        Text(lastOutcome).font(.body.monospaced())
                    }
                }
                .navigationTitle("Sunbay Checkout Demo")
            }
            .navigationViewStyle(.stack)
        }

        /// 用当前 mock 服务组装一个公共入口。
        ///
        /// 通过 `SunbayCheckout(configuration:paymentService:cofService:)` 注入 mock,
        /// 即 Task 11.5 的公共注入缝。配置使用 `.test` 环境,并给一个占位 merchant id
        /// 让 ApplePayButton 的 merchant-id 因素满足(设备因素仍可能为假)。
        private func makeCheckout() -> SunbayCheckout {
            let config = CheckoutConfiguration(
                environment: .test,
                applePayMerchantId: "merchant.com.sunbay.demo",
                locale: "en-US"
            )
            return SunbayCheckout(
                configuration: config,
                paymentService: paymentService,
                cofService: cofService
            )
        }

        /// 把 `CheckoutOutcome` 映射为可读文案(不含任何敏感数据)。
        private func describe(_ outcome: CheckoutOutcome) -> String {
            switch outcome {
            case let .succeeded(txnId):
                return "succeeded(txnId: \(txnId))"
            case let .failed(txnId, error):
                return "failed(txnId: \(txnId ?? "nil"), code: \(error.code), \(error.category))"
            case .canceled:
                return "canceled"
            case let .pending(txnId):
                return "pending(txnId: \(txnId ?? "nil"))"
            case let .unknown(sessionId):
                return "unknown(sessionId: \(sessionId)) → retrievePayment()"
            }
        }
    }

    // MARK: - PaymentSheet 包装(SwiftUI 按钮 → 展示 UIKit 支付页)

    /// 一个 SwiftUI 按钮:点击时在最前的 UIViewController 上 `present` 公共 `PaymentSheet`,
    /// 并把返回的 `CheckoutOutcome` 回传。展示本身走 SDK 公共 API,无内部类型。
    struct PaySheetButton: View {
        let checkout: SunbayCheckout
        let sessionId: String
        let customerAccessSecret: String
        let onOutcome: (CheckoutOutcome) -> Void

        var body: some View {
            Button("Pay (sheet)") {
                guard let presenter = topViewController() else { return }
                let sheet = PaymentSheet(
                    checkout: checkout,
                    sessionId: sessionId,
                    customerAccessSecret: customerAccessSecret
                )
                Task { @MainActor in
                    let outcome = await sheet.present(from: presenter)
                    onOutcome(outcome)
                }
            }
            .buttonStyle(.borderedProminent)
        }
    }

    // MARK: - ApplePayButton 包装(UIKit 控件 → SwiftUI)

    /// 把公共 `ApplePayButton`(UIControl)桥进 SwiftUI,接 `onResult` 与 `onAvailabilityChange`。
    struct ApplePayButtonView: UIViewRepresentable {
        let checkout: SunbayCheckout
        let sessionId: String
        let onResult: (CheckoutOutcome) -> Void
        let onAvailabilityChange: (Bool) -> Void

        func makeUIView(context: Context) -> ApplePayButton {
            let button = ApplePayButton(checkout: checkout, sessionId: sessionId, style: .automatic)
            button.onResult = onResult
            button.onAvailabilityChange = onAvailabilityChange
            // 最小可见外观(SDK 控件自身只上色,无文字)。
            button.setContentHuggingPriority(.defaultLow, for: .horizontal)
            return button
        }

        func updateUIView(_ uiView: ApplePayButton, context: Context) {}
    }

    // MARK: - 取栈顶 VC(用于 present)

    /// 返回当前 key window 最前面的 UIViewController(用于 modally present 支付页)。
    @MainActor
    private func topViewController() -> UIViewController? {
        let scenes = UIApplication.shared.connectedScenes
        let windowScene = scenes.first { $0.activationState == .foregroundActive } as? UIWindowScene
            ?? scenes.first as? UIWindowScene
        guard var top = windowScene?.windows.first(where: { $0.isKeyWindow })?.rootViewController
            ?? windowScene?.windows.first?.rootViewController
        else { return nil }
        while let presented = top.presentedViewController {
            top = presented
        }
        return top
    }

#else

    // MARK: - 非 GUI 宿主回退(例如 macOS host)

    /// SwiftPM 可执行产品需要一个 `main`。在没有 UIKit/SwiftUI 的宿主(macOS host)上,
    /// GUI demo 不可用;打印一条说明即退出,保证该可执行目标在任意宿主都能编译链接
    /// (真实运行目标是 iOS 模拟器,见 Example/README.md)。
    @main
    struct SunbayCheckoutDemoApp {
        static func main() {
            FileHandle.standardError.write(Data(
                "SunbayCheckoutDemo is a UIKit/SwiftUI app; build & run it on the iOS simulator. See Example/README.md.\n".utf8
            ))
        }
    }

#endif
