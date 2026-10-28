import ProjectDescription

// Tuist manifest for the SunbayCheckout Example app.
//
// This produces a REAL Xcode app (not a SwiftPM executable) that consumes only the SDK's
// public API plus the public `SunbayCheckoutMocks` doubles. The SDK lives in the Swift
// package at the repository root, two directories up from this manifest.
//
// Local-package wiring: the root `Package.swift` is declared as a local Swift package via
// `packages: [.package(path: "../..")]`, and the app target depends on the two library
// products by name (`SunbayCheckout`, `SunbayCheckoutMocks`) through `.package(product:)`.
// `tuist generate` resolves them into the generated project.
//
// English/ASCII only. No real merchant certificates or secrets are committed: the Apple Pay
// entitlement carries a PLACEHOLDER merchant id; a real one is configured by the integrating
// developer on-device (see Example/README.md and AGENTS.md section 5).

let project = Project(
    name: "SunbayCheckoutDemo",
    // Disable Tuist's automatic per-target scheme generation so the project exposes exactly one
    // clean, runnable scheme (declared below) instead of several same-named schemes (one of which
    // has no run action and triggers "scheme is not configured for running" in Xcode).
    options: .options(automaticSchemesOptions: .disabled),
    packages: [
        // The SDK Swift package at the repo root (contains SunbayCheckout + SunbayCheckoutMocks).
        .package(path: "../.."),
    ],
    targets: [
        .target(
            name: "SunbayCheckoutDemo",
            destinations: .iOS,
            product: .app,
            bundleId: "com.sunbay.checkout.demo",
            deploymentTargets: .iOS("15.0"),
            infoPlist: .extendingDefault(
                with: [
                    "UILaunchScreen": [:],
                    "UIApplicationSceneManifest": [
                        "UIApplicationSupportsMultipleScenes": false,
                    ],
                ]
            ),
            sources: ["Sources/**"],
            entitlements: .dictionary([
                // Placeholder merchant id. A real integration replaces this with the merchant's
                // own identifier and provisions the matching capability/certificate on device.
                "com.apple.developer.in-app-payments": .array([
                    .string("merchant.com.sunbay.demo"),
                ]),
            ]),
            dependencies: [
                .package(product: "SunbayCheckout"),
                .package(product: "SunbayCheckoutMocks"),
            ]
        ),
    ],
    schemes: [
        // One explicit, runnable scheme for the app target. Building and running this scheme
        // launches SunbayCheckoutDemo.app on a simulator; no other app scheme is generated.
        .scheme(
            name: "SunbayCheckoutDemo",
            shared: true,
            buildAction: .buildAction(targets: ["SunbayCheckoutDemo"]),
            runAction: .runAction(
                configuration: .debug,
                executable: "SunbayCheckoutDemo"
            )
        ),
    ]
)
