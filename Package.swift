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
    ]
)
