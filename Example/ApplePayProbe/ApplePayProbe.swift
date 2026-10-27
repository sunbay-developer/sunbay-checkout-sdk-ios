import Foundation

// MARK: - Apple Pay 真机探针（Task 14）
//
// 独立探针（standalone probe）：**直连 PassKit**，不依赖 SunbayCheckout SDK 目标，
// 也不是 SDK 消费者（不 import SunbayCheckout）。
//
// 目的：验证 Apple Pay **客户端钱包调用链**——能力检测 → 系统 sheet → 读取加密 token，
// 只做脱敏诊断（token 字节长度、是否存在），**绝不**打印/记录原始 token 字节、绝不发往任何后端、
// 绝不发起真实交易（见 AGENTS.md §2.3、product-spec §3.2 / §6.2）。
//
// 商户/网关参数全部为**占位值**（placeholder），TEST/占位环境。真实 merchantIdentifier、
// Apple Pay entitlement、沙箱测试账号 + Wallet 测试卡由开发者在真机上配置（见 README.md）。

#if canImport(UIKit)

    import PassKit
    import SwiftUI
    import UIKit

    // MARK: - 占位配置（非机密，可提交）

    /// 探针使用的占位商户/网关参数。**不是**真实凭证——真机运行需开发者替换 merchantIdentifier
    /// 并在 app target 打开 Apple Pay capability（见 README.md）。
    enum ProbeConfig {
        /// 占位 merchant id（真机需换成已在 Apple Developer 注册的真实 id）。
        static let merchantIdentifier = "merchant.com.sunbay.probe"
        /// 占位国家/地区（TEST）。
        static let countryCode = "US"
        /// 占位币种（TEST）。
        static let currencyCode = "USD"
        /// 占位汇总行：1.00（最小货币单位的直观值，仅用于驱动 sheet，不产生真实扣款）。
        static let summaryLabel = "Sunbay Apple Pay Probe"
        static let summaryAmount = NSDecimalNumber(string: "1.00")
        /// 受支持的卡网络（占位）。
        static let supportedNetworks: [PKPaymentNetwork] = [.visa, .masterCard, .amex]
        /// 商户能力：3DS（PassKit 标准最小集）。
        static let merchantCapabilities: PKMerchantCapability = .threeDSecure
    }

    // MARK: - 探针结果模型（仅脱敏诊断）

    /// 一次探针运行的可读结果。**不含**任何原始 token 字节或敏感数据。
    struct ProbeResult: Equatable {
        /// `PKPaymentAuthorizationController.canMakePayments()` 的结果。
        var canMakePayments: Bool
        /// `canMakePayments(usingNetworks:)`（带受支持网络）的结果。
        var canMakePaymentsUsingNetworks: Bool
        /// 系统授权 sheet 是否成功 present。
        var sheetPresented: Bool
        /// 终态分支的可读描述（授权成功的脱敏 token 诊断 / 用户取消 / 错误）。
        var branch: String

        static let initial = ProbeResult(
            canMakePayments: false,
            canMakePaymentsUsingNetworks: false,
            sheetPresented: false,
            branch: "—"
        )
    }

    // MARK: - 探针核心（PassKit 调用链）

    /// 直连 PassKit 的 Apple Pay 探针。
    ///
    /// 调用链：能力检测 → 构造 `PKPaymentRequest`（占位参数）→ present
    /// `PKPaymentAuthorizationController` → 在 delegate 读取 `payment.token.paymentData`
    /// → 仅产出脱敏诊断（长度 / 是否存在）。
    @MainActor
    final class ApplePayProbe: NSObject, PKPaymentAuthorizationControllerDelegate {
        private var controller: PKPaymentAuthorizationController?
        private var completion: ((ProbeResult) -> Void)?
        private var result = ProbeResult.initial
        /// 标记 delegate 是否已读到授权回调（用于区分「用户取消」与「授权成功」）。
        private var didAuthorize = false

        /// 运行一次探针。回调在主线程。
        ///
        /// - Parameter completion: 带脱敏诊断的 `ProbeResult`。
        func run(completion: @escaping (ProbeResult) -> Void) {
            self.completion = completion
            self.didAuthorize = false
            var r = ProbeResult.initial

            // 1) 能力检测（两种 API）。
            r.canMakePayments = PKPaymentAuthorizationController.canMakePayments()
            r.canMakePaymentsUsingNetworks = PKPaymentAuthorizationController
                .canMakePayments(usingNetworks: ProbeConfig.supportedNetworks)
            self.result = r

            // 2) 构造占位 PKPaymentRequest。
            let request = Self.makeRequest()

            // 3) present 系统授权 sheet。
            let controller = PKPaymentAuthorizationController(paymentRequest: request)
            controller.delegate = self
            self.controller = controller
            controller.present { [weak self] presented in
                Task { @MainActor in
                    guard let self else { return }
                    self.result.sheetPresented = presented
                    if !presented {
                        // sheet 无法展示（设备无能力 / 无卡等）→ 走 no-card/cancel 分支。
                        self.result.branch =
                            "sheet did not present (no Apple Pay capability / no card in Wallet)"
                        self.finish()
                    }
                }
            }
        }

        /// 构造占位 `PKPaymentRequest`（1.00 汇总行、占位商户/网关参数）。
        private static func makeRequest() -> PKPaymentRequest {
            let request = PKPaymentRequest()
            request.merchantIdentifier = ProbeConfig.merchantIdentifier
            request.countryCode = ProbeConfig.countryCode
            request.currencyCode = ProbeConfig.currencyCode
            request.supportedNetworks = ProbeConfig.supportedNetworks
            request.merchantCapabilities = ProbeConfig.merchantCapabilities
            request.paymentSummaryItems = [
                PKPaymentSummaryItem(
                    label: ProbeConfig.summaryLabel,
                    amount: ProbeConfig.summaryAmount
                ),
            ]
            return request
        }

        /// 把一次性结果回传并清理。
        private func finish() {
            let out = result
            let cb = completion
            completion = nil
            controller = nil
            cb?(out)
        }

        // MARK: PKPaymentAuthorizationControllerDelegate

        /// 用户授权成功回调。读取 `payment.token.paymentData` → **仅**脱敏诊断。
        ///
        /// 安全约束（AGENTS.md §2.3、product-spec §3.2 / §5）：
        /// 绝不打印/记录原始 token 字节、绝不发往任何后端、绝不发起真实交易。
        func paymentAuthorizationController(
            _ controller: PKPaymentAuthorizationController,
            didAuthorizePayment payment: PKPayment,
            handler completion: @escaping (PKPaymentAuthorizationResult) -> Void
        ) {
            didAuthorize = true
            let tokenData = payment.token.paymentData
            // 仅脱敏诊断：字节长度 + 是否存在。绝不读出/打印原始字节。
            let present = !tokenData.isEmpty
            result.branch =
                "authorized — token present: \(present ? "yes" : "no"), token byte length: \(tokenData.count) (redacted; raw bytes never logged/sent)"
            // 探针不做真实交易：直接以 success 关闭 sheet（不把 token 发往任何地方）。
            completion(PKPaymentAuthorizationResult(status: .success, errors: nil))
        }

        /// sheet 结束回调（用户取消 或 授权流程完成后系统 dismiss）。
        func paymentAuthorizationControllerDidFinish(
            _ controller: PKPaymentAuthorizationController
        ) {
            controller.dismiss {
                Task { @MainActor in
                    if !self.didAuthorize {
                        // 未经授权即结束 → 用户取消 / 无卡分支（模拟器的预期结局）。
                        self.result.branch =
                            "canceled / no-card branch (user dismissed or Wallet has no usable card)"
                    }
                    self.finish()
                }
            }
        }
    }

    // MARK: - 最小 SwiftUI UI

    /// 探针主屏：一个按钮运行探针，显示 canMakePayments、是否 present、脱敏 token 诊断 / 取消 / 错误分支。
    struct ProbeRootView: View {
        @State private var result = ProbeResult.initial
        @State private var running = false
        private let probe = ApplePayProbe()

        var body: some View {
            NavigationView {
                Form {
                    Section("Capability detection") {
                        row("canMakePayments()", result.canMakePayments ? "true" : "false")
                        row(
                            "canMakePayments(usingNetworks:)",
                            result.canMakePaymentsUsingNetworks ? "true" : "false"
                        )
                    }
                    Section("Sheet") {
                        row("sheet presented", result.sheetPresented ? "yes" : "no")
                    }
                    Section("Result branch (redacted)") {
                        Text(result.branch)
                            .font(.footnote.monospaced())
                            .foregroundStyle(.secondary)
                    }
                    Section {
                        Button(running ? "Running…" : "Run Apple Pay probe") {
                            running = true
                            probe.run { out in
                                result = out
                                running = false
                            }
                        }
                        .disabled(running)
                        .buttonStyle(.borderedProminent)
                    }
                    Section {
                        Text("This probe validates the CLIENT wallet call chain only (capability → sheet → token). No backend, no real charge, redacted diagnostics only. On the iOS Simulator the token path is limited (no real Wallet card), so the expected result is the cancel/no-card branch; real-device token acquisition must be verified by the developer (see README.md).")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .navigationTitle("Apple Pay Probe")
            }
            .navigationViewStyle(.stack)
        }

        private func row(_ label: String, _ value: String) -> some View {
            HStack {
                Text(label)
                Spacer()
                Text(value).font(.body.monospaced()).foregroundStyle(.secondary)
            }
        }
    }

    // MARK: - App 入口（iOS）

    /// 独立探针 App 入口（SwiftUI，iOS 模拟器 / 真机）。不依赖 SunbayCheckout。
    @main
    struct ApplePayProbeApp: App {
        var body: some Scene {
            WindowGroup {
                ProbeRootView()
            }
        }
    }

#else

    // MARK: - 非 iOS 宿主回退（macOS host）

    /// SwiftPM 可执行产品需要一个 `main`。在没有 UIKit 的宿主（macOS host）上，
    /// PassKit 的 `PKPaymentAuthorizationController` UI 路径不可用；打印说明即退出，
    /// 保证该可执行目标在 host 上也能编译链接（`swift build` / `swift test` 绿）。
    /// 真实运行目标是 iOS 模拟器 / 真机（见 Example/ApplePayProbe/README.md）。
    @main
    enum ApplePayProbeApp {
        static func main() {
            FileHandle.standardError.write(Data(
                "ApplePayProbe is an iOS PassKit probe; build & run it on the iOS simulator (expected: cancel/no-card branch) or a real device (full token). See Example/ApplePayProbe/README.md.\n".utf8
            ))
        }
    }

#endif
