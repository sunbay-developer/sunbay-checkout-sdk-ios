# Releasing the Sunbay Checkout iOS SDK

This document describes how the SDK is versioned and distributed today, how to produce
a binary artifact on demand, and the recorded (not-yet-enabled) path to binary Swift
Package Manager distribution.

The **primary and only active distribution mechanism is source Swift Package Manager
(SPM)**. Everything about binary distribution below is on-demand tooling or recorded
future work; nothing in the normal build/test flow depends on it.

---

## 1. Versioning (source SPM)

The SDK is consumed as a source SPM package. Releases are cut by **git tag**, and the
tag IS the SPM version:

- Tags are semantic versions (`MAJOR.MINOR.PATCH`), e.g. `1.4.0`.
- SPM resolves consumer dependencies directly from these git tags
  (`.package(url: ..., from: "1.4.0")` or an exact/range requirement).
- **Breaking changes bump the MAJOR version.** Per `AGENTS.md` section 2, the public
  API is small and stable; any breaking change to the public boundary is a major bump.
  Additive, backward-compatible changes bump MINOR; fixes bump PATCH.

### Cutting a source release

1. Ensure `swift build && swift test` pass (all tests green).
2. Update the changelog / release notes as appropriate.
3. Create and push an annotated semantic-version tag:
   ```bash
   git tag -a 1.4.0 -m "1.4.0"
   git push origin 1.4.0
   ```
4. Consumers pick up the new version through their SPM dependency requirement.

No binary artifact is produced or required for a source release.

---

## 2. Producing a binary on demand

Occasionally a consumer needs a prebuilt binary instead of building from source -- for
example, to evaluate integration without compiling the package, or for an environment
where source SPM is inconvenient. For that case there is an **on-demand** packaging
script:

```bash
./scripts/build-xcframework.sh
```

What it does:

- Archives the `SunbayCheckout` library product twice (device: `generic/platform=iOS`,
  simulator: `generic/platform=iOS Simulator`) with
  `SKIP_INSTALL=NO BUILD_LIBRARY_FOR_DISTRIBUTION=YES`.
- Combines both slices with `xcodebuild -create-xcframework` into
  `build/SunbayCheckout.xcframework`.
- Packages **only** the `SunbayCheckout` product -- not `SunbayCheckoutTestSupport`, not
  the Example app (`SunbayCheckoutDemo`), not `ApplePayProbe`.
- Produces **no signed artifacts and no secrets**: the output is an unsigned,
  distributable library artifact. No merchant keys, certificates, tokens, or card data
  are involved.

All output lives under `build/`, which is git-ignored. The script is not part of the
normal build/test flow and nothing depends on it.

> **Environment note.** Archiving a *pure-SwiftPM* library scheme into a distributable
> `.framework` can be finicky: in some toolchains `xcodebuild archive` on the SPM scheme
> emits only a raw object file rather than a `.framework` bundle, in which case
> `-create-xcframework` has nothing to consume and the script **fails loudly** (non-zero
> exit) rather than producing an empty/invalid artifact. When that happens, producing a
> real `.xcframework` requires wrapping the SPM product in a framework target (e.g. a
> Tuist/Xcode framework project) before archiving. This wrapping is deferred to the C3
> work below.

### How a consumer uses the produced `.xcframework` today

Binary SPM distribution is **not** enabled yet (see section 3), so a consumer integrates
the produced `.xcframework` **manually**:

1. Obtain `build/SunbayCheckout.xcframework` (run the script, or receive the artifact).
2. Drag `SunbayCheckout.xcframework` into the Xcode project (or add it under the target's
   **Frameworks, Libraries, and Embedded Content**).
3. Set it to **Embed & Sign** (the host app signs it; the SDK ships unsigned).
4. `import SunbayCheckout` and use the public API as usual.

This manual drag-in path is a stopgap for binary consumers; the source SPM package
remains the supported integration.

---

## 3. Future: binary SPM distribution (C3) -- recorded, NOT enabled

Binary SPM distribution via `.binaryTarget(url:checksum:)` is a **recorded future step
(C3)**, intentionally not enabled now. A commented `.binaryTarget` skeleton is left in
`Package.swift` at the switch point so the change is visible and easy to locate.

**Precondition -- do NOT turn this on until all of the following are true:**

- The real backend is integrated (the mock-baseline contract in `product-spec.md` section 7
  has been replaced by the real adapter).
- The public API is **frozen**.
- The product is **officially released**.

**C3 checklist (when the preconditions are met):**

1. Build the `.xcframework` (using the framework-wrapped product; see the environment
   note in section 2) via `scripts/build-xcframework.sh`.
2. Host the `.xcframework` (zipped) at a stable URL -- e.g. a GitHub Release asset for the
   tag.
3. Compute the checksum against the hosted zip:
   ```bash
   swift package compute-checksum SunbayCheckout.xcframework.zip
   ```
4. Wire CI to build the `.xcframework` and upload it on tag, and to record the checksum.
5. Flip the package target to the binary target by uncommenting the
   `.binaryTarget(name:url:checksum:)` skeleton in `Package.swift` and wiring the
   `SunbayCheckout` product to it (using the hosted URL and computed checksum).

Until every precondition holds, the SDK stays source SPM and the `.binaryTarget` skeleton
stays commented out.

---

## 4. Not planned

- **CocoaPods** distribution is not planned.
