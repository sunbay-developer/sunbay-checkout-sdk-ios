// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "SunbayCheckout",
    defaultLocalization: "en",
    platforms: [
        .iOS(.v15),
    ],
    products: [
        .library(
            name: "SunbayCheckout",
            targets: ["SunbayCheckout"]
        ),
        // Public-API-only scriptable backend doubles, shared by the e2e test target and the Example
        // app (a separate Xcode/Tuist project). Exposed as a library product so the Example app can
        // depend on it without internal access.
        .library(
            name: "SunbayCheckoutMocks",
            targets: ["SunbayCheckoutMocks"]
        ),
        // 示例 demo 可执行产品(Task 13)。只消费 SunbayCheckout 公共 API + 公共
        // PaymentService/CofService 协议;真实运行目标是 iOS 模拟器(见 Example/README.md)。
        .executable(
            name: "SunbayCheckoutDemo",
            targets: ["SunbayCheckoutDemo"]
        ),
        // Apple Pay 真机探针(Task 14)。**独立**可执行产品:直连 PassKit,
        // **不依赖** SunbayCheckout(不是 SDK 消费者)。真实运行目标是 iOS 模拟器/真机
        // (见 Example/ApplePayProbe/README.md)。
        .executable(
            name: "ApplePayProbe",
            targets: ["ApplePayProbe"]
        ),
    ],
    targets: [
        .target(
            name: "SunbayCheckout",
            path: "Sources/SunbayCheckout",
            resources: [.process("Resources/Localizations")]
        ),
        // Public-API-only scriptable backend doubles (ScriptablePaymentService, ScriptableCofService,
        // DemoSessionFactory). Depends only on SunbayCheckout's public API (no @testable, no UIKit),
        // so it builds on the macOS host and is consumable by both the e2e test target and the Example app.
        .target(
            name: "SunbayCheckoutMocks",
            dependencies: ["SunbayCheckout"],
            path: "Sources/SunbayCheckoutMocks"
        ),
        .testTarget(
            name: "SunbayCheckoutTests",
            dependencies: ["SunbayCheckout", "SunbayCheckoutMocks"],
            path: "Tests/SunbayCheckoutTests"
        ),
        // 示例 demo 目标:仅依赖 SunbayCheckout(公共 API),源码在 Example 下。
        .executableTarget(
            name: "SunbayCheckoutDemo",
            dependencies: ["SunbayCheckout"],
            path: "Example/SunbayCheckoutDemo"
        ),
        // Apple Pay 真机探针目标:**无 dependencies**(直连 PassKit,独立于 SunbayCheckout),
        // 源码在 Example/ApplePayProbe 下。iOS-only 代码用 `#if canImport(UIKit)` 包裹,
        // 另有 macOS-host `#else main` 回退,保证在 host 上也能编译链接。
        .executableTarget(
            name: "ApplePayProbe",
            path: "Example/ApplePayProbe",
            exclude: ["README.md"]
        ),
    ]
)
