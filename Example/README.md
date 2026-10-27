# SunbayCheckout — Example app

A minimal, **mock-backed** demo of the SunbayCheckout iOS SDK. It consumes only the
SDK's **public API** (`SunbayCheckout`, `PaymentSheet`, `ApplePayButton`,
`CheckoutOutcome`, `CheckoutError`) plus the public `PaymentService` / `CofService`
protocols — no internal types, no `@testable`, no real backend, and no secrets.

## What it demonstrates

- **PaymentSheet (L1 black-box)** — a "Pay (sheet)" button constructs
  `PaymentSheet(checkout:sessionId:customerAccessSecret: "demo_secret")` and calls
  `present(from:)`. The sheet renders:
  - a **new-card** form + a "Save this card" toggle (new-card path; the card is RSA-encrypted
    locally by the SDK's `CardEncryptor` using the demo public key below),
  - the **two mock saved cards** (COF one-tap — select a card and pay, zero extra host code,
    because the mock session has `cofEnabled = true` and we pass a `customerAccessSecret`),
  - an **Apple Pay entry row** (see the note below).
  The returned `CheckoutOutcome` is shown on screen.
- **Standalone ApplePayButton (L3)** — placed directly on the screen, with `onResult`
  wired to show the outcome and `onAvailabilityChange` wired to reflect availability. This is
  the working wallet path: tapping it drives `authorize → confirmWallet` end-to-end.
- **All five outcomes** — the "Scenario" picker scripts the mock `submit` result so you can
  observe `succeeded` / `failed` / `pending` / `requiresAction`, plus a "Network timeout →
  unknown" scenario (the mock throws on `submit`, so the SDK resolves to `unknown(sessionId:)`
  and would recover via `retrievePayment()` → `getResult`).

The injected `MockDemoPaymentService` returns a scripted `CheckoutSession` (demo
`rsaPublicKey`, `cofEnabled = true`, methods `[.card, .applePay, .savedCard]`, a
`42.99 USD` amount, merchant "Sunbay Demo Store"), and `MockDemoCofService` returns two
scripted `SavedCard`s. They are injected through the **public injection seam**:

```swift
SunbayCheckout(configuration:paymentService:cofService:)   // Task 11.5 seam
```

## In-sheet Apple Pay (known v-next wiring item)

The Apple Pay **row inside the PaymentSheet** is currently a cancel-only placeholder in the
SDK (`PaymentSheetViewController` reports `.cancel` for that row; wiring it to real wallet
authorization would require changing SDK internals, which is out of scope for this task).

**The working wallet path in this release is the standalone `ApplePayButton`**, which drives
`confirmWallet` end-to-end and is fully exercised by this demo. Wiring the in-sheet Apple Pay
row to real authorization is a v-next item.

## The demo RSA key

`MockDemoBackend.swift` embeds a **throwaway demo RSA public key** (`DemoRSAKey`,
PKCS#1 `RSAPublicKey` DER, base64). It is a **public key** (not a secret), generated once for
this demo so the SDK's `CardEncryptor` can import it and produce valid ciphertext. The
matching private key was discarded and never committed — no real backend can decrypt with it.
**Do not** use this key in a real integration; the real public key is delivered by the backend
via the session.

## How it's built (SwiftPM executable target)

The demo is a **SwiftPM executable target** (`SunbayCheckoutDemo` in the root `Package.swift`),
not a separate Xcode project. It depends on the `SunbayCheckout` library and lives under
`Example/SunbayCheckoutDemo/`. This keeps everything in one package with no checked-in
`.xcodeproj`. Xcode auto-generates a `SunbayCheckoutDemo` scheme from the package.

## Build & run on a simulator

Open the package in Xcode (`File ▸ Open…` the `ios/` folder) and either run the
`SunbayCheckoutDemo` scheme on an iOS Simulator, or from the command line:

```bash
# from checkout-sdk-native/ios
xcodebuild -scheme SunbayCheckoutDemo \
  -destination 'platform=iOS Simulator,name=iPhone 16' \
  build
```

This compiles **and links** the demo for the iOS simulator against the SDK's public API.
(Plain `swift build` compiles the sources but links the executable product with the host
macOS triple — use `xcodebuild` with an iOS Simulator destination to get a simulator binary.)

To run it, use the Xcode scheme (Cmd-R). The app launches to a single screen with the scenario
picker, the "Pay (sheet)" button, the standalone Apple Pay button, and a "Last outcome" field.

> The executable product is a bare Mach-O binary; the Xcode scheme wraps it in an app bundle
> for install/launch on the simulator.
