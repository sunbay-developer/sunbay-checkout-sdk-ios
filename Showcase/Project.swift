import ProjectDescription

// Tuist manifest for the Showcase app: a fake-merchant demo that consumes only the public
// SunbayCheckout API from the Swift package at the repository root.
//
// No signing material is committed. Overrides (read at generate time via Tuist `Environment`):
//   TUIST_SUNBAY_SHOWCASE_MERCHANT_ID       (default: merchant.native.com.sunbay.dev)
//   TUIST_SUNBAY_SHOWCASE_BUNDLE_ID         (default: com.sunbay.checkout.showcase)
//   TUIST_SUNBAY_SHOWCASE_DEVELOPMENT_TEAM  (default: none; the simulator needs none)

private let merchantId = Environment.sunbayShowcaseMerchantId.getString(default: "merchant.native.com.sunbay.dev")
private let bundleId = Environment.sunbayShowcaseBundleId.getString(default: "com.sunbay.checkout.showcase")
private let developmentTeam = Environment.sunbayShowcaseDevelopmentTeam.getString(default: "")

private let signingSettings: SettingsDictionary = developmentTeam.isEmpty
    ? [:]
    : ["DEVELOPMENT_TEAM": .string(developmentTeam)]

let project = Project(
    name: "Showcase",
    options: .options(automaticSchemesOptions: .disabled),
    packages: [
        .package(path: ".."),
    ],
    targets: [
        .target(
            name: "Showcase",
            destinations: .iOS,
            product: .app,
            bundleId: bundleId,
            deploymentTargets: .iOS("15.0"),
            infoPlist: .extendingDefault(
                with: [
                    "CFBundleDisplayName": "SBC Showcase",
                    "CFBundleDevelopmentRegion": "en",
                    "CFBundleLocalizations": ["en", "zh-Hans"],
                    // Export compliance: declared as not using non-exempt encryption so TestFlight
                    // builds skip the per-build questionnaire. Decision owned by the app owner.
                    "ITSAppUsesNonExemptEncryption": false,
                    "ShowcaseMerchantId": .string(merchantId),
                    // Enables the SDK's on-device "Scan card" button (it auto-hides without this key).
                    "NSCameraUsageDescription": "Used to scan your card number on-device. Images are never stored or sent.",
                    "UILaunchScreen": [:],
                    "UIApplicationSceneManifest": [
                        "UIApplicationSupportsMultipleScenes": false,
                    ],
                ]
            ),
            sources: ["App/**", "Shared/**"],
            resources: ["Resources/**"],
            entitlements: .dictionary([
                "com.apple.developer.in-app-payments": .array([
                    .string(merchantId),
                ]),
            ]),
            dependencies: [
                .package(product: "SunbayCheckout"),
            ],
            settings: .settings(base: signingSettings.merging(["ASSETCATALOG_COMPILER_APPICON_NAME": "AppIcon"]) { $1 })
        ),
        .target(
            name: "ShowcaseTests",
            destinations: .iOS,
            product: .unitTests,
            bundleId: bundleId + ".tests",
            deploymentTargets: .iOS("15.0"),
            infoPlist: .default,
            sources: ["Tests/**"],
            dependencies: [
                .target(name: "Showcase"),
            ]
        ),
    ],
    schemes: [
        .scheme(
            name: "Showcase",
            shared: true,
            buildAction: .buildAction(targets: ["Showcase"]),
            testAction: .targets(["ShowcaseTests"]),
            runAction: .runAction(
                configuration: .debug,
                executable: "Showcase"
            )
        ),
    ]
)
