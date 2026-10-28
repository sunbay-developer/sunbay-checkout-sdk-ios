# Sunbay Checkout iOS SDK

Native payment SDK for embedding **Sunbay Checkout** into iOS apps. It renders native payment UI —
a card form, an Apple Pay button, and a saved-card (COF) list — collects card data in native
controls, encrypts it locally with an RSA public key, and submits it directly to the Sunbay backend.

> **Status:** architecture & design phase. This repo currently contains the design spec only; the
> Swift package and example apps are to be implemented. See `docs/product-spec.md`.

## Approach

- **Pure native** — no embedded WebView for card collection. The card form is native UIKit.
- Three UI layers, planned once, delivered by version:
  - **L1 `PaymentSheet`** — black-box full-screen page (first release)
  - **L3 `ApplePayButton`** — standalone wallet button (first release)
  - **L2 `EmbeddedPaymentElement`** — host-embedded block (reserved for v2)
- **COF (saved cards)** is a first-release feature: list saved cards and pay in one tap.

## Quick start (target API, not yet implemented)

```swift
let checkout = SunbayCheckout(
    configuration: .init()   // defaults to .production; pass environment: .dev / .test to target a non-production backend
)

// L1 — black-box sheet
let sheet = PaymentSheet(
    checkout: checkout,
    sessionId: sessionId,                 // created server-side by the merchant backend
    customerAccessSecret: customerAccessSecret  // COF only; delivered over HTTPS
)
let outcome = await sheet.present(from: self)

// L3 — standalone Apple Pay button
let button = ApplePayButton(checkout: checkout, sessionId: sessionId)
button.onResult = { outcome in /* ... */ }
```

## Distribution

Swift Package Manager (primary). XCFramework reserved/on-demand. CocoaPods not planned.

## Docs

- [`docs/product-spec.md`](docs/product-spec.md) — full self-contained design (architecture, public
  API, data flows, state machine, backend contract baseline, COF model).
- [`docs/security-and-pci.md`](docs/security-and-pci.md) — security hard rules and PCI assessment.
- [`AGENTS.md`](AGENTS.md) — development conventions.

## Security

Card data is collected only inside the SDK's native controls, encrypted locally, and never exposed
to host-app code, logs, or any public callback. See `docs/security-and-pci.md`.
