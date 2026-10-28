# SDK Distribution Hardening Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Rename the shared mocks product to a clearly-labeled `SunbayCheckoutTestSupport`, add a cross-package integration smoke test, and add an on-demand XCFramework packaging script plus a release-process document.

**Architecture:** Three independent, sequential changes to the packaging/distribution surface — a module rename at the SPM product boundary (a), a standalone consumer package that depends on the SDK by local path (b), and a shell packaging script + docs (c). No change to `SunbayCheckout`'s own public API, Core/UI logic, or the source-SPM distribution mechanism.

**Tech Stack:** Swift 5.9, SwiftPM (products/targets/`.binaryTarget`), Tuist (Example manifest), `xcodebuild -create-xcframework`, XCTest.

**Spec:** `docs/superpowers/specs/2026-10-28-sdk-distribution-hardening-design.md`

## Global Constraints

- Swift only; min iOS target `.iOS(.v15)`.
- English/ASCII only in all code, comments, identifiers, test names, scripts, docs, commit messages.
- Primary distribution stays **source SPM**; this work does not change the distribution mechanism.
- Intended products after this work: `SunbayCheckout` (real SDK) + `SunbayCheckoutTestSupport` (labeled test scaffolding, non-stable API, not for production). No other library products.
- No merchant certs/keys/tokens/private keys committed; the demo RSA key stays a public key. `build/` and `IntegrationSmokeTest/.build/` are git-ignored.
- `swift test` must stay green (64 tests: 55 `SunbayCheckoutTests` + 9 `SunbayCheckoutE2ETests`) after the rename.
- Core stays UI-agnostic; no logging/persistence changes (this work is packaging/naming only).

## Review Focus

- **Stale `SunbayCheckoutMocks` reference after rename** (any of the 10 call sites, or the Example Tuist project): a missed import/product reference breaks the build — the rename must be complete across `Package.swift`, the Example manifest, Example sources, and all test files. Pinned in Task 1 (full-tree grep step + `swift test` + Example generate/build).
- **Smoke-test package accidentally depending on `SunbayCheckoutTestSupport`**: it must depend ONLY on the real `SunbayCheckout` product, or it stops proving the clean public-integration surface. Pinned in Task 2.
- **Smoke-test package not actually resolving the SDK** (e.g. wrong relative path `.package(path:)`): the build would pass trivially without exercising cross-package resolution. Pinned in Task 2 (the smoke source must reference a real public symbol so resolution is load-bearing).
- **XCFramework script silently producing nothing / only one slice**: a script that exits 0 without a valid device+simulator `.xcframework` gives false confidence. Pinned in Task 3 (script verifies the output `.xcframework` exists and contains both slices).
- **`build/` artifacts getting committed**: large binary artifacts in git. Pinned in Task 3 (.gitignore entry + the script writing only under `build/`).

---

## Task 1: Rename SunbayCheckoutMocks → SunbayCheckoutTestSupport (labeled test-support product)

**Files:**
- Move: `Sources/SunbayCheckoutMocks/{ScriptablePaymentService,ScriptableCofService,DemoSessionFactory}.swift` → `Sources/SunbayCheckoutTestSupport/` (content unchanged except added header doc comment)
- Modify: `Package.swift` (rename product + target; update `SunbayCheckoutTests` dependency)
- Modify: `Example/SunbayCheckoutDemo/Project.swift` (`.package(product: "SunbayCheckoutTestSupport")`)
- Modify: `Example/SunbayCheckoutDemo/Sources/{DemoApp,DemoRootView,DemoSettings}.swift` (`import SunbayCheckoutTestSupport`)
- Modify: `Tests/SunbayCheckoutE2ETests/{E2ESupport,CheckoutFlowE2ETests,CheckoutInvariantsE2ETests,LocalizationE2ETests}.swift` (`import`)
- Modify: `Tests/SunbayCheckoutTests/Support/ScriptableServiceSmokeTests.swift` (`import`)

**Interfaces:**
- Produces: a library product+target named `SunbayCheckoutTestSupport` exposing the same public types as before (`ScriptablePaymentService`, `ScriptableCofService`, `DemoSessionFactory`, `DemoRSAKey`), consumed by Task-nothing-downstream-in-code but by the Example app and test targets. Task 2's smoke package deliberately does NOT depend on it.

- [ ] **Step 1: Move the source directory and rename product/target**

`git mv Sources/SunbayCheckoutMocks Sources/SunbayCheckoutTestSupport`. In `Package.swift` rename the `.library(name:)`, the `.target(name:path:)` (path → `Sources/SunbayCheckoutTestSupport`), and the `"SunbayCheckoutMocks"` entry in `SunbayCheckoutTests` dependencies — all to `SunbayCheckoutTestSupport`.

- [ ] **Step 2: Add the test-support label**

Add a top-of-file doc comment to each of the three moved files, and a comment above the product/target in `Package.swift`, stating: this module is **test/example scaffolding** (scriptable service doubles + demo fixtures), **not a stable public API**, and **must not be used in production integrations**. English/ASCII only.

- [ ] **Step 3: Update all importers**

Change `import SunbayCheckoutMocks` → `import SunbayCheckoutTestSupport` in the four E2E test files, the one unit-test support file, and the three Example `Sources/` files; change `.package(product: "SunbayCheckoutMocks")` → `"SunbayCheckoutTestSupport"` in `Example/SunbayCheckoutDemo/Project.swift`.

- [ ] **Step 4: Verify no stale reference remains**

Run: `grep -rn "SunbayCheckoutMocks" . --include="*.swift" | grep -v "/.build/" | grep -v "/Derived/"`
Expected: no output (zero matches).

- [ ] **Step 5: Verify the package still builds and tests pass**

Run: `swift test`
Expected: PASS, 64 tests (55 + 9), 0 failures.

- [ ] **Step 6: Verify the Example app still generates and builds**

Run: `cd Example/SunbayCheckoutDemo && tuist generate --no-open && xcodebuild -workspace SunbayCheckoutDemo.xcworkspace -scheme SunbayCheckoutDemo -destination 'platform=iOS Simulator,name=iPhone 17' build`
Expected: project generated + BUILD SUCCEEDED. (If iPhone 17 is unavailable, use any installed iOS Simulator from `xcrun simctl list devices available`.)

- [ ] **Step 7: Commit**

```bash
git add Package.swift Sources/SunbayCheckoutTestSupport Example/SunbayCheckoutDemo Tests/SunbayCheckoutE2ETests Tests/SunbayCheckoutTests
git commit -m "refactor: rename SunbayCheckoutMocks to labeled SunbayCheckoutTestSupport product"
```

---

## Task 2: Cross-package integration smoke test

**Files:**
- Create: `IntegrationSmokeTest/Package.swift`
- Create: `IntegrationSmokeTest/Sources/IntegrationSmokeTest/SmokeMain.swift`
- Modify: `.gitignore` (add `IntegrationSmokeTest/.build/`)

**Interfaces:**
- Consumes: the SDK's public `SunbayCheckout` product only (NOT `SunbayCheckoutTestSupport`), via `.package(path: "..")`.
- Produces: a standalone package that builds with `swift build`, proving clean cross-package integration.

- [ ] **Step 1: Write the consumer manifest**

`IntegrationSmokeTest/Package.swift`: a package named `IntegrationSmokeTest`, platforms `.iOS(.v15)` + a host platform so `swift build` works on macOS (mirror the SDK's platform floor; add `.macOS(.v12)` so the executable links on the host like the SDK's own targets do), one executable target `IntegrationSmokeTest` depending on `.product(name: "SunbayCheckout", package: "SunbayCheckout")` from `.package(path: "..")`. Depend ONLY on `SunbayCheckout` — not on `SunbayCheckoutTestSupport`.

- [ ] **Step 2: Write the load-bearing smoke source**

`SmokeMain.swift`: `import SunbayCheckout` and reference a representative slice of the public API so resolution is load-bearing (the build fails if a public symbol is missing). Minimal content: construct a `CheckoutConfiguration(environment: .test, locale: "en-US")`, instantiate `SunbayCheckout(configuration:)`, and reference `CheckoutOutcome` / `CheckoutError` types (e.g. in a function signature or a `_ =` binding). Guard any UIKit-only touch out — use only cross-platform public types so it links on the host. English/ASCII only.

- [ ] **Step 3: Verify the smoke source is load-bearing**

The smoke source must reference real public symbols (Step 2), so the build can only succeed when the SDK dependency is correctly resolved and those symbols exist. Confirm this by reading the source: it imports `SunbayCheckout` and uses `CheckoutConfiguration` + `SunbayCheckout` + `CheckoutOutcome`/`CheckoutError`. (No destructive check needed — if the `.package(path: "..")` or any referenced symbol were wrong, Step 4's build would fail.)
Expected: the source references at least three distinct public SDK symbols.

- [ ] **Step 4: Verify clean integration builds**

Run: `cd IntegrationSmokeTest && swift build`
Expected: BUILD complete — the standalone package resolves `SunbayCheckout` across the package boundary and compiles against its public API.

- [ ] **Step 5: Confirm it does NOT see test-support**

Run: `grep -n "SunbayCheckoutTestSupport" IntegrationSmokeTest/Package.swift IntegrationSmokeTest/Sources/IntegrationSmokeTest/SmokeMain.swift`
Expected: no output (the smoke test depends only on the real product).

- [ ] **Step 6: Commit**

```bash
git add IntegrationSmokeTest .gitignore
git commit -m "test: add cross-package integration smoke test consuming SunbayCheckout"
```

---

## Task 3: On-demand XCFramework packaging script + release doc

**Files:**
- Create: `scripts/build-xcframework.sh` (executable)
- Create: `docs/releasing.md`
- Modify: `.gitignore` (add `build/`)
- Modify: `Package.swift` (append a commented `.binaryTarget(url:checksum:)` skeleton block — not enabled)

**Interfaces:**
- Consumes: the `SunbayCheckout` library product.
- Produces: `build/SunbayCheckout.xcframework` on demand (git-ignored); `docs/releasing.md`.

- [ ] **Step 1: Write the packaging script**

`scripts/build-xcframework.sh` (bash, `set -euo pipefail`): archive the `SunbayCheckout` scheme/product for `generic/platform=iOS` and `generic/platform=iOS Simulator` with `SKIP_INSTALL=NO BUILD_LIBRARY_FOR_DISTRIBUTION=YES` into two `.xcarchive`s under `build/`, then `xcodebuild -create-xcframework` combining both into `build/SunbayCheckout.xcframework`. Header comment: packages only the `SunbayCheckout` product (not test-support, not the Example app), min iOS 15, produces no signed/secret artifacts. English/ASCII only.

- [ ] **Step 2: Make it executable and ignore outputs**

`chmod +x scripts/build-xcframework.sh`. Add `build/` to `.gitignore`.

- [ ] **Step 3: Run the script and verify a valid xcframework is produced**

Run: `./scripts/build-xcframework.sh && ls build/SunbayCheckout.xcframework && /usr/libexec/PlistBuddy -c "Print :AvailableLibraries" build/SunbayCheckout.xcframework/Info.plist 2>/dev/null || cat build/SunbayCheckout.xcframework/Info.plist`
Expected: `build/SunbayCheckout.xcframework` exists and its `Info.plist` lists TWO libraries (an `ios` device slice and an `ios-simulator` slice). If the environment cannot archive (no matching SDK), the script must still fail loudly (non-zero) rather than exit 0 with no output — note the outcome in the report.

- [ ] **Step 4: Write the release doc + commented binaryTarget skeleton**

`docs/releasing.md`: document (1) source-SPM versioning (git tag → SPM version; breaking = major bump); (2) when/how to run `scripts/build-xcframework.sh` and how a consumer uses the produced `.xcframework` manually today; (3) the recorded future C3 path — turning on binary SPM distribution after the real backend is integrated and the API is frozen — with the checklist (host the artifact, compute `swift package compute-checksum`, wire CI on tag). Append a COMMENTED `.binaryTarget(name:url:checksum:)` skeleton to `Package.swift` (commented out, with a one-line note pointing to `docs/releasing.md`), so the switch point is visible but not enabled.

- [ ] **Step 5: Verify the package still builds with the commented skeleton present**

Run: `swift build && swift test`
Expected: PASS (the commented block is inert; 64 tests stay green).

- [ ] **Step 6: Commit**

```bash
git add scripts/build-xcframework.sh docs/releasing.md .gitignore Package.swift
git commit -m "build: add on-demand XCFramework script and release process doc"
```

---

## Notes on recorded future work (not in this plan)

- **C3 — binary SPM distribution:** enable the `.binaryTarget(url:checksum:)` (skeleton left commented in `Package.swift`), host the `.xcframework`, wire CI to build+upload on tag. Deferred until the real backend is integrated, the public API is frozen, and the product is officially released.
- **CocoaPods:** not planned.
