import ProjectDescription

// Tuist manifest for the Showcase app: a fake-merchant demo that consumes only the public
// SunbayCheckout API from the Swift package at the repository root.
//
// No signing material is committed. Overrides (read at generate time via Tuist `Environment`):
//   TUIST_SUNBAY_SHOWCASE_MERCHANT_ID       (default: merchant.com.sunbay.demo)
//   TUIST_SUNBAY_SHOWCASE_BUNDLE_ID         (default: com.sunbay.checkout.showcase)
//   TUIST_SUNBAY_SHOWCASE_DEVELOPMENT_TEAM  (default: none; the simulator needs none)

private let merchantId = Environment.sunbayShowcaseMerchantId.getString(default: "merchant.com.sunbay.demo")
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
                    "CFBundleDisplayName": "Sunbay Showcase",
                    "ShowcaseMerchantId": .string(merchantId),
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
