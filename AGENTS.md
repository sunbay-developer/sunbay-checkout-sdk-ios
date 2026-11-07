# AGENTS.md — Sunbay Checkout iOS SDK

Development conventions for all AI agents and engineers working in this repository.
**Read this file and `docs/product-spec.md` in full before touching payment code.**

This repository is a **standalone git repo** (independent from the `checkout` web repo and the
`checkout-sdk-native/android` repo). It must be fully self-contained: all context needed to build
the SDK lives in `docs/`. Do not assume access to the `checkout` repo at runtime.

---

## 1. What this is

The **Sunbay Checkout iOS SDK** — a native payment SDK embedded by ISV apps (the customer's own
iPhone app). It renders native payment UI (card form, Apple Pay button, saved-card list) and
confirms payments against the Sunbay backend.

**Pure-native approach.** Card data is collected in native UIKit controls, RSA-encrypted locally,
and sent directly to the backend. There is **no embedded WebView for card collection** — the earlier
WebView-hosted-page experiment (`sunbay-pay-sdk`) is abandoned.

First release ships **L1 (PaymentSheet, black-box page)** and **L3 (ApplePayButton)**; **L2
(EmbeddedPaymentElement)** is reserved for v2. COF (saved cards) is a **first-release** feature.

Full design: `docs/product-spec.md`. Security/PCI: `docs/security-and-pci.md`.

---

## 2. Hard rules (non-negotiable)

1. **Swift only.** Follow Apple's official APIs (PassKit, Swift Concurrency, URLSession) and payment
   brand guidelines. Minimum iOS target locked after real-device verification (prototype: iOS 15).
2. **English only in code and docs.** All source code — comments, doc comments, identifiers,
   string literals, test names, commit messages — and all repo docs (`README.md`, `AGENTS.md`,
   `docs/`) are written in **English**. Chinese is allowed only in external spec/brainstorming
   artifacts and in conversation, never inside this repository. (Technical terms stay in English.)
3. **Small, stable public API.** Internal types must not leak across the public boundary. Semantic
   versioning; breaking changes bump major.
3. **Card values, wallet tokens, COF secrets, and the RSA-encrypted payload must never** be written
   to logs, analytics, crash reports, or any public callback/return value.
4. **Sensitive data boundary is cohesive.** Only `CardEncryptor` touches plaintext card data; only
   `CredentialStore` holds secrets. Plaintext is zeroed immediately after encryption. Nothing
   sensitive is persisted (no UserDefaults / file / Keychain / UIPasteboard).
5. **Payment truth = server-confirmed terminal state; the SDK does not poll for it.** Wallet
   authorization success only means a token was obtained, not that the transaction succeeded. The
   submit lock covers only the in-flight submit request and is released the moment the request
   returns (success / failure / processing), never waiting on a poll or a backend terminal state.
   The SDK does not client-poll the backend for the result: an async-undetermined result is
   reported as `pending` / `unknown` (never `failed`), and the host reconciles via
   `retrievePayment` / webhook. On a lost response within one in-flight attempt the SDK may query
   once (not a loop) before concluding `unknown`; it never blindly resubmits. See
   `docs/superpowers/specs/2026-11-06-submit-lock-and-no-poll-realignment-design.md`.
6. **Core is UI-agnostic.** `CheckoutController` and the Core layer import no UIKit/PassKit UI types;
   they depend on protocols only. This is what makes L2 a zero-rework addition later.
7. **Backend contract is not final.** The contract in `docs/product-spec.md` §7 is derived from
   existing web behavior and is a **mock baseline**. Build `PaymentService`/`CofService` behind
   protocols so the mock can be swapped for the real adapter without touching Core/UI. Features
   built ahead of their API are tracked in `docs/real-api-integration-checklist.md`; read it before
   wiring any real endpoint and update it when you build something against a mock.

## 3. Code organization

See `docs/product-spec.md` §6.2 for the full tree. In short:
`Sources/SunbayCheckout/{Public, UI, Core}` + `Tests` + `Example/{SunbayCheckoutDemo, ApplePayProbe}`.
Distribution: **Swift Package Manager** primary; XCFramework reserved/on-demand; CocoaPods not planned.

The tree also now includes:
- `Sources/SunbayCheckout/UI/{Theme, Content, Content/Components, Container}/` — the redesigned UI layer:
  `Theme/` (ResolvedAppearance / ColorHex / AppearanceDefaults), the host-agnostic `Content/` layer
  (`CheckoutContentViewController` + the `Content/Components/` views) and the `Container/` layer
  (`PaymentSheetContainerViewController`, L1 bottom sheet, plus the custom bottom-sheet presentation
  stack `BottomSheet{Geometry,Layout,PresentationAnimator,PresentationController,PresentationStyle,TransitioningDelegate}.swift`
  and the pure sizing helper `SheetSizingMath.swift`). Dependency is one-way
  `Container → Content → Theme`; this split is what makes L2 embedded a zero-rework addition.
  See `docs/superpowers/specs/2026-11-03-checkout-sdk-ui-redesign-design.md`.
- `Sources/SunbayCheckout/Core/AddressMetadata/` — the `AddressMetadataService` protocol + models +
  TTL/dedup cache (`AddressMetadataCache`) + HTTP adapter (`HTTPAddressMetadataService`) + the fail-soft
  `EmptyAddressMetadataService` default (no UIKit; full-mode address, protocol + UI + cache only this phase,
  not wired to real data).
- `Sources/SunbayCheckout/Core/Localization/` + `Sources/SunbayCheckout/Resources/Localizations/{en,zh-Hans}.lproj/` —
  the i18n subsystem and its string resources (v1 ships en-US + zh-CN). See `docs/product-spec.md` §9.
- `Sources/SunbayCheckoutTestSupport/` — a public-API-only library target (scriptable service doubles + demo
  fixtures) shared by the e2e target and the Example app; depends on no internal types.
- `Example/SunbayCheckoutDemo/` — a Tuist-generated Xcode app (`Project.swift` + `Sources/` checked in;
  the generated `*.xcodeproj`/`*.xcworkspace`/`Derived/` are git-ignored). This is the SDK-consuming
  real-device/demo surface and the UI localization gate. `Example/ApplePayProbe/` remains the standalone
  PassKit probe.
- `Tests/SunbayCheckoutE2ETests/` — a protocol-driven e2e target that runs on the host via `swift test`
  (no UIKit), alongside `Tests/SunbayCheckoutTests/`.

## 4. Testing & verification

- XCTest covering state machine, RSA encryption, idempotency/dedup, recovery. `swift test` must pass.
- First release verification: mock example app (full UI/state flow incl. COF) + Apple Pay
  **real-device probe** (capability → wallet sheet → token, no real backend). Real/sandbox
  end-to-end is a release gate after the backend is ready.
- Do not add tests beyond what is asked; when changing tested logic, update its tests.

## 5. Git conventions

- Standalone git repo, default branch `main`. **Do not develop directly on
  `main`**; open `feature/<scope>`, `fix/<scope>`, or `chore/<scope>` branches
  per team conventions.
- Do not commit unless the user explicitly asks; when committing, `git add`
  precise files — **never `git add .`**.
- Files that may contain secrets (`.env*`, credentials, token-bearing npmrc)
  **must not be committed**.
- Push the working branch by default; do not push directly to `main`.