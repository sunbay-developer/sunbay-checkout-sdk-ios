# Sunbay Checkout iOS SDK — Distribution Hardening (Design)

> Status: design, pending implementation plan
> Date: 2026-10-28
> Scope: three coordinated improvements to the SDK's distribution/packaging surface —
> (1) rename the shared mocks target to a clearly-labeled test-support product,
> (2) a cross-package integration smoke test, and (3) an on-demand XCFramework
> packaging script plus a release-process document. This is the agreed design brief
> from brainstorming.
> Convention: written in English per AGENTS.md section 2.

---

## 0. Background & intent

The SDK is distributed as a **source Swift Package (SPM)**, which is the mainstream primary
channel for a new iOS SDK (AGENTS.md section 3: "SwiftPM primary; XCFramework reserved/on-demand;
CocoaPods not planned"). Three gaps remain between the current state and the mainstream shape that
mature payment SDKs (e.g. Stripe iOS) ship:

1. **Test doubles leak into the public product surface.** `SunbayCheckoutMocks` is currently a
   public library **product**, so an integrator who adds the package sees it alongside the real
   `SunbayCheckout` product with nothing signalling "this is test scaffolding, not a stable API."
2. **No verification that the published package integrates cleanly.** All tests run inside the
   package itself; nothing exercises the real "another package resolves and depends on
   `SunbayCheckout`" path, where product visibility, resource bundling, and `defaultLocalization`
   actually surface.
3. **No way to produce a binary artifact.** Payment SDKs are routinely asked for a pre-compiled
   `.xcframework` (to protect implementation detail and speed integrator builds). There is no
   packaging path today, and no documented release process tying git tags to SPM versions.

This work closes all three while keeping the primary channel unchanged (source SPM) and the main
product surface minimal.

### Decisions locked during brainstorming

- **(a) Mocks → test-support product (mainstream, Stripe-style).** Keep it as its own product so the
  in-repo Example app and tests can depend on it cleanly, but **rename** it to
  `SunbayCheckoutTestSupport` and label it (naming + doc comments) as test scaffolding, non-stable
  API, not for production. Mirrors Stripe's `StripePaymentsTestUtils` / `*TestSupport` convention.
- **(b) Cross-package integration smoke test.** A separate consumer package inside the repo that
  depends on the SDK via a **local path** dependency (`.package(path: "../..")`), built in CI with
  `swift build`. This genuinely exercises SPM cross-package resolution without needing network or a
  published tag.
- **(c) On-demand XCFramework packaging + release doc.** A `scripts/build-xcframework.sh` that
  produces a `.xcframework` from the `SunbayCheckout` product on demand, plus a `docs/releasing.md`
  covering tag→version and the future binary-distribution path, with a commented
  `.binaryTarget(url:checksum:)` skeleton left in place (not enabled).

### Recorded for later (explicitly NOT in this work)

- **C3 — true binary SPM distribution.** Enabling `.binaryTarget(url:checksum:)` wired to a hosted
  `.xcframework` (GitHub Release / CDN) produced automatically by CI on tag. This is the mainstream
  end state (Stripe ships source SPM + CocoaPods + binary XCFramework together), but it is
  deliberately deferred until **the real backend is integrated, the public API is frozen, and the
  product is officially released**, because it requires hosting infrastructure and locks binary
  artifacts while the SDK is still iterating in source form. C2 (below) is the no-rework stepping
  stone to it.

### Alignment with Stripe iOS (the same-shape reference)

Stripe iOS: distributes source SPM + CocoaPods + a pre-compiled XCFramework; ships test helpers as
a clearly-separated module (`StripePaymentsTestUtils`), not mixed into the payment product; produces
the XCFramework through its release tooling on tag. This design adopts the same separation (a) and
the same "binary on tag" shape as the future (c→C3) target, scaled to this repo's current stage.

---

## 1. (a) Rename mocks to a test-support product

### 1.1 What changes

- Rename the target and its directory: `Sources/SunbayCheckoutMocks/` →
  `Sources/SunbayCheckoutTestSupport/`. The three files move unchanged in content:
  `ScriptablePaymentService.swift`, `ScriptableCofService.swift`, `DemoSessionFactory.swift`
  (carrying `DemoRSAKey`).
- `Package.swift`: the product and target are renamed `SunbayCheckoutMocks` →
  `SunbayCheckoutTestSupport`. It remains a `.library` product (so the Example app, a separate Tuist
  project, can depend on it) and a `.target` depending on `SunbayCheckout`.
- Add a top-of-file doc comment to each test-support source and a `Package.swift` comment stating:
  this product is **test/example scaffolding** (scriptable service doubles + demo fixtures), is
  **not a stable public API**, and **must not be used in production integrations**. This is the
  label that makes the separation meaningful — the mainstream signal an integrator reads.
- The public types inside keep their behavior; only the module name changes. (`ScriptablePaymentService`
  etc. stay as they are — the rename is at the module/product boundary.)

### 1.2 Call sites to update (verified)

Ten files reference the old module name and must switch to `import SunbayCheckoutTestSupport` (or the
new product name in manifests):

- `Package.swift` (product + target + the `SunbayCheckoutTests` dependency entry)
- `Example/SunbayCheckoutDemo/Project.swift` (`.package(product:)`)
- `Example/SunbayCheckoutDemo/Sources/{DemoApp,DemoRootView,DemoSettings}.swift` (`import`)
- `Tests/SunbayCheckoutE2ETests/{E2ESupport,CheckoutFlowE2ETests,CheckoutInvariantsE2ETests,LocalizationE2ETests}.swift` (`import`)
- `Tests/SunbayCheckoutTests/Support/ScriptableServiceSmokeTests.swift` (`import`)

### 1.3 Boundary note

The main product surface an integrator sees becomes: **`SunbayCheckout`** (the real SDK) and
**`SunbayCheckoutTestSupport`** (clearly labeled scaffolding). There is intentionally no attempt to
make the test-support product fully invisible (that was considered and rejected in favor of the
mainstream labeled-product approach), because the Example app — a separate Xcode/Tuist project — needs
a real product to depend on, and Stripe-style labeling communicates the boundary without contorting
the dependency graph.

---

## 2. (b) Cross-package integration smoke test

### 2.1 What it is

A minimal, standalone consumer package committed under `IntegrationSmokeTest/` (sibling layout,
outside `Sources/`), with its own `Package.swift` that depends on the SDK via a local path:

```
IntegrationSmokeTest/
  Package.swift            # depends on .package(path: "..") → the SDK
  Sources/IntegrationSmokeTest/SmokeMain.swift
```

- The consumer package declares a dependency on the SDK's **public** product only
  (`SunbayCheckout`) — NOT on `SunbayCheckoutTestSupport` (the smoke test verifies the real
  integration surface, not the scaffolding).
- `SmokeMain.swift` imports `SunbayCheckout` and touches a small, representative slice of the public
  API (e.g. construct a `CheckoutConfiguration`, reference `CheckoutOutcome` / `CheckoutError`,
  instantiate `SunbayCheckout`) so the build fails if a public symbol is missing, a product is
  misconfigured, or resource bundling / `defaultLocalization` breaks across the package boundary.
- It is an executable or a test target that compiles — it does not hit the network and does not
  require a published tag.

### 2.2 How it runs

- Locally and in CI: `cd IntegrationSmokeTest && swift build`.
- It is intentionally a **separate** package (its own `Package.swift`), so `swift build` there
  performs real SPM cross-package resolution of the SDK — the thing the in-package test suite cannot
  exercise.

### 2.3 Scope

- v1 proves **buildability of a clean integration**, not runtime behavior (the e2e target already
  owns behavior). One representative compile-touch of the public API is enough; do not duplicate
  functional assertions here.
- Platform: the consumer package targets the same floors as the SDK (iOS 15; builds on the host for
  the compile check, consistent with how `swift build`/`swift test` run in this repo).

---

## 3. (c) On-demand XCFramework packaging + release process

### 3.1 Packaging script

- `scripts/build-xcframework.sh`: archives the `SunbayCheckout` library for device + simulator and
  runs `xcodebuild -create-xcframework` to produce `build/SunbayCheckout.xcframework`.
- Output goes under `build/` (git-ignored). The script is **on-demand** — nothing in the normal
  `swift build` / `swift test` / Example flow depends on it.
- The script is self-contained and documented: it states the min iOS target, that it packages only
  the `SunbayCheckout` product (not test-support, not the Example app), and that it produces no
  signed/secret artifacts.

### 3.2 Release-process document

- `docs/releasing.md`: documents the mainstream release shape for this SDK —
  - **Source SPM versioning:** how a git tag (semantic version) maps to an SPM version; breaking
    changes bump major (AGENTS.md section 2).
  - **Producing a binary on demand:** when/why to run `scripts/build-xcframework.sh`, and how a
    consumer would currently use the produced `.xcframework` manually.
  - **Future C3 path (recorded, not enabled):** a commented `.binaryTarget(url:checksum:)` skeleton
    (either in `docs/releasing.md` or as a commented block in `Package.swift`) showing exactly what
    changes when binary SPM distribution is turned on after release, plus the checklist (host the
    artifact, compute checksum, wire CI on tag). This is the no-rework bridge to C3.

### 3.3 Scope

- v1 does **not** change the distribution mechanism: the package stays source SPM. The script and doc
  only *add the ability* to produce a binary and *document* the path to binary distribution.
- No CI automation of the XCFramework in v1 (that is part of C3). The script is runnable by hand.

---

## 4. Implementation order & relationships

`a → b → c`:

- **(a) first** — it changes the product surface (`SunbayCheckoutMocks` → `SunbayCheckoutTestSupport`)
  that everything else references.
- **(b) second** — the smoke test asserts the public product surface, which is cleanest to write
  against the post-rename names (it depends only on `SunbayCheckout`, but lives in the same repo whose
  manifest (a) just edited).
- **(c) last** — independent of (a)/(b); packages the `SunbayCheckout` product and documents release.

---

## 5. Impact & constraints checklist

- **Public API / product surface:** the only intended products after this work are `SunbayCheckout`
  (real SDK) and `SunbayCheckoutTestSupport` (labeled scaffolding). No change to the `SunbayCheckout`
  public API types themselves. The rename is a module-name change, which is a source-breaking change
  for anyone importing `SunbayCheckoutMocks` — acceptable because that module was only ever consumed
  in-repo (Example app + tests) and was never a promised stable API (its whole point, now made
  explicit by the rename/label).
- **English/ASCII only** in all new/changed code, comments, identifiers, script, and docs
  (AGENTS.md section 2).
- **Secrets/signing:** the XCFramework script produces no signed or secret artifacts; no merchant
  certs/keys/tokens. The demo RSA key remains a public key inside test-support. Generated `build/`
  and `IntegrationSmokeTest/.build/` are git-ignored.
- **Core stays UI-agnostic / sensitive-data boundary unchanged:** this work touches packaging and
  module names only; no Core/UI logic, no logging, no persistence changes.
- **`swift test` must stay green** after the rename (all 64 tests), and `cd IntegrationSmokeTest &&
  swift build` plus `scripts/build-xcframework.sh` must succeed.

---

## 6. Future extensions (recorded)

- **C3 — binary SPM distribution:** enable `.binaryTarget(url:checksum:)` against a hosted
  `.xcframework` produced by CI on tag. Do after the real backend is integrated, the public API is
  frozen, and the product is officially released.
- **CocoaPods:** not planned (AGENTS.md section 3); revisit only if a customer requires it.
