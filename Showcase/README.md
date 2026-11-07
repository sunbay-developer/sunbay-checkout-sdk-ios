# Sunbay Checkout Showcase

Home-screen name: **SBC Showcase** (short enough not to be truncated under the icon).

A simulated merchant app (a coffee shop, "Sunbay Coffee") that demonstrates the SunbayCheckout iOS SDK to leaders and customers.
It consumes only the SDK's **public API**. **All payments are simulated; nothing is ever charged.**

## Flow

Browse the menu -> add to cart -> Cart -> Pay -> native `PaymentSheet` (card form, saved cards,
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

Open the workspace in Xcode and run the `Showcase` scheme, or run the unit tests:

```bash
xcodebuild test -scheme Showcase -destination 'platform=iOS Simulator,name=iPhone 17'
```

Substitute the name of any simulator installed on your machine.

Environment variables read at generation time (no signing material is committed):

| Variable | Default | Purpose |
| --- | --- | --- |
| `TUIST_SUNBAY_SHOWCASE_MERCHANT_ID` | `merchant.native.com.sunbay.dev` | Apple Pay merchant id (entitlement and SDK configuration) |
| `TUIST_SUNBAY_SHOWCASE_BUNDLE_ID` | `com.sunbay.checkout.showcase` | App bundle id (the test target uses it plus `.tests`) |
| `TUIST_SUNBAY_SHOWCASE_DEVELOPMENT_TEAM` | empty | Apple development team id |

These names differ from the Example app's (`SUNBAY_DEMO_*` there, `SUNBAY_SHOWCASE_*` here).

The default `merchant.native.com.sunbay.dev` is Sunbay's **internal** test merchant: the Showcase
is an internal demo app, so it ships with it. It only works on a device signed with Sunbay's team.
Integrators should not copy it; see `Example/README.md` for the integrator setup.

Merchant id flow: the generate-time value is written to the entitlement and to Info.plist as
`ShowcaseMerchantId`; the app reads it from `Bundle.main` at runtime and passes it to the SDK
(falling back to `merchant.native.com.sunbay.dev`).

## Demo notes

- Test card: `4242 4242 4242 4242`, any future expiry date, any CVC. The same hint is shown on
  the Cart screen.
- The Apple Pay row only appears with a real merchant id and a signed, Apple Pay-capable device.
- No shipping address is collected (`Appearance.shippingAddressMode = .off`); billing uses the
  SDK default simple form (country / address / postal code).

## TestFlight

The project is structured so Archive works once the owner sets the bundle id, team and merchant id.

- Archive needs the owner's team id via `TUIST_SUNBAY_SHOWCASE_DEVELOPMENT_TEAM`.
- Upload to App Store Connect is done by the owner with their own team and bundle id.
- Internal testers: leaders. External testing link: customers.
- The first external build needs Beta App Review.
- Builds expire after 90 days.
- TestFlight builds will prompt for export compliance; the owner decides `ITSAppUsesNonExemptEncryption` (it is not set here).
- An app icon exists, but the owner may replace it.

Shared code is under `Shared/`, so an App Clip could be added as a future target.
