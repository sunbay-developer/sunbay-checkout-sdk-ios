# Sunbay Checkout - Showcase app

A simulated merchant app that demonstrates the SunbayCheckout iOS SDK to leaders and customers.
It consumes only the SDK's **public API**. **All payments are simulated; nothing is ever charged.**

## Flow

Browse products -> add to cart -> Cart -> Pay -> native `PaymentSheet` (card form, saved cards,
Apple Pay) -> simulated success -> order confirmation, with a callback panel showing the
transaction id and state transitions only (no card data). The cart is cleared after success.

Settings (sheet) lets you switch:

- **Theme**: three presets, applied through the SDK `Appearance`.
- **Mode**: light / dark / system, linked to the SDK color scheme.
- **Language**: English / Chinese (UI strings live in `Shared/Strings/Strings.swift`).

## Generate and run

```bash
cd Showcase
tuist generate          # produces Showcase.xcworkspace / .xcodeproj (git-ignored)
```

Open the workspace in Xcode and run the `Showcase` scheme, or:

```bash
xcodebuild test -scheme Showcase -destination 'platform=iOS Simulator,name=iPhone 17 Pro'
```

Environment variables read at generation time (no signing material is committed):

| Variable | Default | Purpose |
| --- | --- | --- |
| `TUIST_SUNBAY_SHOWCASE_MERCHANT_ID` | `merchant.com.sunbay.demo` | Apple Pay merchant id entitlement |
| `TUIST_SUNBAY_SHOWCASE_DEVELOPMENT_TEAM` | empty | Apple development team id |

The bundle id is `com.sunbay.checkout.showcase`.

## Demo notes

- Test card: `4242 4242 4242 4242`, any future expiry date, any CVC. The same hint is shown on
  the Cart screen.
- The Apple Pay row only appears with a real merchant id and a signed, Apple Pay-capable device.
- The new-card form shows a collapsed "Shipping address" header with "Same as billing" checked.
  This is the SDK default; the Showcase offers no shipping.

## TestFlight

The project is structured so Archive works once the owner sets the bundle id, team and merchant id.

- Upload to App Store Connect is done by the owner with their own team and bundle id.
- Internal testers: leaders. External testing link: customers.
- The first external build needs Beta App Review.
- Builds expire after 90 days.

Shared code is under `Shared/`, so an App Clip could be added as a future target.
