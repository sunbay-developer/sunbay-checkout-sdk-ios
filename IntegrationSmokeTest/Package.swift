// swift-tools-version:5.9
import PackageDescription

// Standalone consumer package that depends on the SunbayCheckout SDK by local path.
// Its sole purpose is to prove that the published package integrates cleanly across the
// package boundary: `swift build` here performs real SPM cross-package resolution of the
// SDK and compiles an executable against its public API only.
let package = Package(
    name: "IntegrationSmokeTest",
    platforms: [
        .iOS(.v15),
        .macOS(.v12),
    ],
    dependencies: [
        // The SDK repo root is one directory up from IntegrationSmokeTest/.
        .package(path: ".."),
    ],
    targets: [
        .executableTarget(
            name: "IntegrationSmokeTest",
            dependencies: [
                // Depend ONLY on the real public SDK product, never on the test-support product.
                // For a path dependency, SPM derives the package identity from the directory
                // name (the SDK repo root is the `ios` directory), not the manifest's declared
                // package name, so reference it as `package: "ios"`.
                .product(name: "SunbayCheckout", package: "ios"),
            ]
        ),
    ]
)
