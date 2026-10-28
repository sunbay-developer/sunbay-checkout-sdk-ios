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
// English/ASCII only. No real merchant certificates or team ids are committed. The Apple Pay
// entitlement carries a PLACEHOLDER merchant id by default; a developer who wants to sign for a
// real device overrides it (and the signing team) via Tuist environment variables read below, so
// their internal values never land in this repository. See Example/README.md and AGENTS.md
// section 5.
//
// Overrides (Tuist reads TUIST_-prefixed env vars at generate time via the `Environment` API):
//   TUIST_SUNBAY_DEMO_MERCHANT_ID       e.g. merchant.com.sunbay.dev   (default: merchant.com.sunbay.demo)
//   TUIST_SUNBAY_DEMO_DEVELOPMENT_TEAM  your Apple Developer Team id    (default: none; the simulator needs none)

// The Apple Pay merchant id. A real device needs one registered under the signing team; the
// default is a non-functional placeholder suitable for the simulator and for committing.
private let merchantId = Environment.sunbayDemoMerchantId.getString(default: "merchant.com.sunbay.demo")

// Optional signing team. When set, it flows into the target's build settings so Xcode can produce
// a provisioning profile that includes the Apple Pay capability for a real device. Left empty for
// the simulator (which does not sign).
private let developmentTeam = Environment.sunbayDemoDevelopmentTeam.getString(default: "")

private let signingSettings: SettingsDictionary = developmentTeam.isEmpty
    ? [:]
    : ["DEVELOPMENT_TEAM": .string(developmentTeam)]

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
                // Merchant id for the Apple Pay capability. Defaults to a non-functional
                // placeholder; override with SUNBAY_DEMO_MERCHANT_ID for real-device signing.
                "com.apple.developer.in-app-payments": .array([
                    .string(merchantId),
                ]),
            ]),
            dependencies: [
                .package(product: "SunbayCheckout"),
                .package(product: "SunbayCheckoutMocks"),
            ],
            settings: .settings(base: signingSettings)
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
