# Sunbay Checkout iOS SDK

Native payment SDK for embedding **Sunbay Checkout** into iOS apps. It renders native payment UI —
a card form, an Apple Pay button, and a saved-card (COF) list — collects card data in native
controls, encrypts it locally with an RSA public key, and submits it directly to the Sunbay backend.

> **Status:** UI layer implemented (first-release L1 + L3 + COF). The Swift package, example app, and
> host/simulator test suites are in place; real/sandbox backend end-to-end is the remaining release gate.
> See `docs/product-spec.md`.

## Approach

- **Pure native** — no embedded WebView for card collection. The card form is native UIKit.
- Three UI layers, planned once, delivered by version:
  - **L1 `PaymentSheet`** — black-box bottom-sheet page (first release)
  - **L3 `ApplePayButton`** — standalone wallet button (first release)
  - **L2 `EmbeddedPaymentElement`** — host-embedded block (reserved for v2)
- **COF (saved cards)** is a first-release feature: list saved cards and pay in one tap.

## Quick start

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
// Optional: observe the in-sheet presentation state (editing / processing / succeeded / failed).
sheet.onStateChange = { state in /* ... */ }
let outcome = await sheet.present(from: self)

// L3 — standalone Apple Pay button
let button = ApplePayButton(checkout: checkout, sessionId: sessionId)
button.onResult = { outcome in /* ... */ }
```

## Apple Pay merchant id

Apple Pay needs **your own** merchant id, registered in your Apple Developer account and added to
your app's Apple Pay capability (`com.apple.developer.in-app-payments`). Pass it to the SDK:

```swift
let checkout = SunbayCheckout(
    configuration: .init(applePayMerchantId: "merchant.com.yourcompany.yourapp")
)
```

If you omit it, the SDK uses the merchant id delivered with the session. The id in your
entitlement and the one you pass here must match. The example app uses the placeholder
`merchant.com.example.yourapp`; replace it with yours (see `Example/README.md`).

## Theming (`Appearance`)

`Appearance` is a Stripe-style nested value type, consumed by the UI layer and injected into every
component. Every color is an optional `UIColor` — leave it `nil` to use the built-in dynamic default.

```swift
var appearance = Appearance()                 // or Appearance.default
appearance.colors.primary = UIColor(sunbayHex: "#ff6000")  // public hex convenience; nil on invalid input
appearance.cornerRadius = 10
appearance.expressPosition = .top             // Apple Pay row on the home page: .top / .bottom / .off
appearance.density = .comfortable             // .comfortable / .compact
appearance.colorScheme = .automatic           // .automatic (follow system) / .light / .dark

let config = CheckoutConfiguration(appearance: appearance)
```

- **Dark / light.** Built-in defaults are dynamic colors that adapt to the trait collection;
  `colorScheme` drives `overrideUserInterfaceStyle` so merchants can follow the system or lock to
  `.light` / `.dark`.
- **Address collection.** Whether an address form is shown follows the checkout session; the host can only
  turn one off with `appearance.billingAddressEnabled = false` / `shippingAddressEnabled = false`.
  `billingAddressStyle` / `shippingAddressStyle` choose `.simple` (country / line1 / postal code) or `.full`
  (backend-layout driven).

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
