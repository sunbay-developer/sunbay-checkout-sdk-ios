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
        // TEST/EXAMPLE SCAFFOLDING ONLY: scriptable service doubles + demo fixtures, shared by the
        // test targets and the Example app (a separate Xcode/Tuist project). Exposed as a library
        // product so the Example app can depend on it without internal access. This is NOT a stable
        // public API and MUST NOT be used in production integrations.
        .library(
            name: "SunbayCheckoutTestSupport",
            targets: ["SunbayCheckoutTestSupport"]
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
        // TEST/EXAMPLE SCAFFOLDING ONLY: scriptable service doubles + demo fixtures
        // (ScriptablePaymentService, ScriptableCofService, DemoSessionFactory). Depends only on
        // SunbayCheckout's public API (no @testable, no UIKit), so it builds on the macOS host and is
        // consumable by both the test targets and the Example app. This is NOT a stable public API
        // and MUST NOT be used in production integrations.
        .target(
            name: "SunbayCheckoutTestSupport",
            dependencies: ["SunbayCheckout"],
            path: "Sources/SunbayCheckoutTestSupport"
        ),
        .testTarget(
            name: "SunbayCheckoutTests",
            dependencies: ["SunbayCheckout", "SunbayCheckoutTestSupport"],
            path: "Tests/SunbayCheckoutTests"
        ),
        // Protocol-driven e2e target: drives the internal Core CheckoutController through all five
        // CheckoutOutcome results via `@testable import SunbayCheckout` (our own harness, not a host
        // integrator), using the public scriptable doubles from SunbayCheckoutTestSupport.
        .testTarget(
            name: "SunbayCheckoutE2ETests",
            dependencies: ["SunbayCheckout", "SunbayCheckoutTestSupport"],
            path: "Tests/SunbayCheckoutE2ETests"
        ),
        // The SunbayCheckoutDemo executable target has been migrated to a standalone Tuist-generated
        // Xcode app (see Example/SunbayCheckoutDemo/Project.swift); it is no longer a SwiftPM target.
        // Apple Pay 真机探针目标:**无 dependencies**(直连 PassKit,独立于 SunbayCheckout),
        // 源码在 Example/ApplePayProbe 下。iOS-only 代码用 `#if canImport(UIKit)` 包裹,
        // 另有 macOS-host `#else main` 回退,保证在 host 上也能编译链接。
        .executableTarget(
            name: "ApplePayProbe",
            path: "Example/ApplePayProbe",
            exclude: ["README.md"]
        ),
        // FUTURE (C3 -- NOT ENABLED): binary SPM distribution switch point. See docs/releasing.md.
        // When the real backend is integrated, the public API is frozen, and the product is
        // officially released, host the SunbayCheckout.xcframework, compute its checksum with
        // `swift package compute-checksum`, then enable the binary target below and wire the
        // `SunbayCheckout` library product to it. This stays COMMENTED so the package builds from
        // source exactly as it does today.
        // NOTE: this binary target reuses the name "SunbayCheckout", which collides with the
        // existing source `.target(name: "SunbayCheckout")`. When enabling, REPLACE the source
        // target (do not keep both) -- SwiftPM forbids two targets sharing a name.
        // .binaryTarget(
        //     name: "SunbayCheckout",
        //     url: "https://example.com/SunbayCheckout/<version>/SunbayCheckout.xcframework.zip",
        //     checksum: "<swift package compute-checksum output>"
        // ),
    ]
)
