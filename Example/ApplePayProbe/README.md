# Apple Pay real-device probe

A **standalone** Apple Pay probe (Task 14). It talks to **PassKit directly** and is
**independent of the SunbayCheckout SDK** — it does **not** import `SunbayCheckout` and is
**not** an SDK consumer. It exists purely to validate the Apple Pay client call chain on a real
device before the SDK's wallet path is wired to a real backend.

## 1. What this probe validates (and what it does NOT)

It validates the **CLIENT wallet call chain only**:

```
capability detection → system Apple Pay sheet → encrypted wallet token
```

Concretely it:

- calls `PKPaymentAuthorizationController.canMakePayments()` and
  `canMakePayments(usingNetworks:)` (capability detection),
- builds a `PKPaymentRequest` with **placeholder** merchant/gateway params (placeholder
  `merchantIdentifier` `merchant.com.sunbay.probe`, TEST/placeholder country `US`, currency
  `USD`, supported networks visa / masterCard / amex, `.threeDSecure`, a single `1.00` summary
  item),
- presents `PKPaymentAuthorizationController`,
- in the delegate reads `payment.token.paymentData` and shows **only redacted diagnostics**
  (token present yes/no, token byte length).

It deliberately does **NOT**:

- **No backend.** The token is never sent anywhere.
- **No real charge / no real transaction.** The probe closes the sheet with `.success` purely to
  dismiss the UI; nothing is submitted.
- **No raw token logging.** The raw `paymentData` bytes are never printed, logged, or returned —
  only the length and a present/absent flag (per AGENTS.md §2.3 and product-spec §3.2 / §5).

The minimal SwiftUI UI has one button that runs the probe and displays: the `canMakePayments`
results, whether the sheet presented, and the redacted token diagnostic (length / present) or the
cancel / error branch.

## 2. Entitlement / merchant-id setup to run it on a REAL device

This SwiftPM target compiles and links for the iOS simulator, but a **full token acquisition on a
real device** requires Apple Pay entitlement and a configured merchant — which cannot live in this
repo (no certificates/secrets are committed). To run it on a real device a developer must:

1. **Apple Pay capability in the app target.** Add the **Apple Pay** capability (the
   `com.apple.developer.in-app-payments` entitlement) to the app target that hosts this probe. A
   bare SwiftPM executable product has no entitlement/`Info.plist`; to run on a device, wrap these
   sources in an Xcode **app** target (or add an app wrapper) and enable Apple Pay on it.
2. **A real `merchantIdentifier`.** Register a merchant ID in the Apple Developer account (e.g.
   `merchant.com.<yourorg>.<app>`), attach it to the capability, and replace the placeholder
   `ProbeConfig.merchantIdentifier` (`merchant.com.sunbay.probe`) in `ApplePayProbe.swift` with it.
   The placeholder will not produce a usable sheet on a device.
3. **A sandbox tester + a test card in Wallet.** Sign in to the device with an **Apple sandbox
   tester** account and add a **test card** to Wallet (per Apple's Apple Pay sandbox testing
   guide). Without a usable card the sheet reaches the no-card branch.

Once set up, tapping **Run Apple Pay probe** should reach the authorized branch and report the
redacted token diagnostic (present: yes, non-zero byte length).

## 3. iOS Simulator behavior (expected outcome here)

On the **iOS Simulator** the sheet / token path is limited: the simulator Wallet has no real
usable cards, so the **expected simulator result is typically the cancel / no-card branch** (the
sheet may not present, or presents and ends without an authorization). **That is the expected
simulator outcome, not a failure.**

The **full token acquisition (authorized branch with a real token)** must be verified on a
**real device** by the developer, following §2. That real-device verification is the outstanding
manual step for this probe — it cannot be completed in a simulator-only / no-entitlement
environment.

## 4. No real certificates / secrets

This directory commits **no** merchant certificates, private keys, gateway credentials, or real
card data. All merchant/gateway values in `ProbeConfig` are **placeholders** and are safe to
commit; they are not usable for a real charge. Do not add real certificates or secrets here — the
real merchant ID and entitlement live in the developer's Apple Developer account and signed app
target, not in this repository (AGENTS.md §5).

## 5. Build & run

It is a SwiftPM executable target (`ApplePayProbe` in the root `Package.swift`), independent of
`SunbayCheckout`. iOS code is under `#if canImport(UIKit)`; a macOS-host `#else main` fallback lets
the executable compile on the host (so `swift build` / `swift test` stay green).

```bash
# from checkout-sdk-native/ios — build the probe for the iOS simulator
xcodebuild -scheme ApplePayProbe \
  -destination 'platform=iOS Simulator,name=iPhone 16' \
  build
```

To run it on the simulator, use the Xcode scheme (Cmd-R) — expected outcome is the cancel/no-card
branch (see §3). For the full token path, run it on a real device per §2.
