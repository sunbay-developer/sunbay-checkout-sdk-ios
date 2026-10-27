// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "SunbayCheckout",
    platforms: [
        .iOS(.v15),
    ],
    products: [
        .library(
            name: "SunbayCheckout",
            targets: ["SunbayCheckout"]
        ),
        // 示例 demo 可执行产品(Task 13)。只消费 SunbayCheckout 公共 API + 公共
        // PaymentService/CofService 协议;真实运行目标是 iOS 模拟器(见 Example/README.md)。
        .executable(
            name: "SunbayCheckoutDemo",
            targets: ["SunbayCheckoutDemo"]
        ),
    ],
    targets: [
        .target(
            name: "SunbayCheckout",
            path: "Sources/SunbayCheckout"
        ),
        .testTarget(
            name: "SunbayCheckoutTests",
            dependencies: ["SunbayCheckout"],
            path: "Tests/SunbayCheckoutTests"
        ),
        // 示例 demo 目标:仅依赖 SunbayCheckout(公共 API),源码在 Example 下。
        .executableTarget(
            name: "SunbayCheckoutDemo",
            dependencies: ["SunbayCheckout"],
            path: "Example/SunbayCheckoutDemo"
        ),
    ]
)
