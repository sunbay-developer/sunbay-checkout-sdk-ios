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
2. **Small, stable public API.** Internal types must not leak across the public boundary. Semantic
   versioning; breaking changes bump major.
3. **Card values, wallet tokens, COF secrets, and the RSA-encrypted payload must never** be written
   to logs, analytics, crash reports, or any public callback/return value.
4. **Sensitive data boundary is cohesive.** Only `CardEncryptor` touches plaintext card data; only
   `CredentialStore` holds secrets. Plaintext is zeroed immediately after encryption. Nothing
   sensitive is persisted (no UserDefaults / file / Keychain / UIPasteboard).
5. **Payment truth = server-confirmed terminal state.** Wallet authorization success only means a
   token was obtained, not that the transaction succeeded. On timeout / app relaunch, query by
   session/transaction first — never blindly resubmit.
6. **Core is UI-agnostic.** `CheckoutController` and the Core layer import no UIKit/PassKit UI types;
   they depend on protocols only. This is what makes L2 a zero-rework addition later.
7. **Backend contract is not final.** The contract in `docs/product-spec.md` §7 is derived from
   existing web behavior and is a **mock baseline**. Build `PaymentService`/`CofService` behind
   protocols so the mock can be swapped for the real adapter without touching Core/UI.

## 3. Code organization

See `docs/product-spec.md` §6.2 for the full tree. In short:
`Sources/SunbayCheckout/{Public, UI, Core}` + `Tests` + `Example/{SunbayCheckoutDemo, ApplePayProbe}`.
Distribution: **Swift Package Manager** primary; XCFramework reserved/on-demand; CocoaPods not planned.

## 4. Testing & verification

- XCTest covering state machine, RSA encryption, idempotency/dedup, recovery. `swift test` must pass.
- First release verification: mock example app (full UI/state flow incl. COF) + Apple Pay
  **real-device probe** (capability → wallet sheet → token, no real backend). Real/sandbox
  end-to-end is a release gate after the backend is ready.
- Do not add tests beyond what is asked; when changing tested logic, update its tests.

## 5. Git & secrets

- No merchant keys, certificates, production tokens, or real card data in the repo.
- Stage specific files by name (no `git add .`). Do not commit/push unless explicitly asked.
- Example apps call only the public API with mock/sandbox config; never depend on internal types.
