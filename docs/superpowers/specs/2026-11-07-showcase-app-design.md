# Sunbay Checkout Showcase app — design

Date: 2026-11-07
Status: DRAFT (awaiting approval)
Scope: new top-level `Showcase/` Tuist project. No SDK source changes.

## 1. Intent

`Example/SunbayCheckoutDemo` is a developer playground: it exposes every integration knob and is
used for real-device testing. It is not suitable for showing leaders and customers.

The Showcase is a small, polished **fake merchant app** that demonstrates the SDK the way a real
customer would experience it: pick products, open the cart, tap Pay, complete the SDK payment
sheet, return to the merchant app and see the payment result and the SDK callback. Its second job
is to show that the SDK **follows the merchant's theme** (brand color, corner radius, light/dark).

Audience: leaders and customers, on a real iPhone (TestFlight) or a simulator, plus screen recordings.

## 2. Goals / non-goals / anti-goals

Goals
- Clear, simple, good-looking flow: Shop -> Cart -> SDK payment sheet -> Result.
- The merchant app has light/dark/system mode and 3 preset color themes; the SDK sheet matches the
  current merchant theme and mode at the moment it is presented.
- Every payment succeeds (simulated). The result screen shows the real values the SDK returned
  (`CheckoutOutcome.succeeded(txnId:)` and the `onStateChange` sequence).
- After a successful payment the cart is empty and products must be added again.
- EN / Chinese language switch that drives both the merchant UI and `CheckoutConfiguration.locale`.
- Archive-ready for TestFlight (see §8).

Non-goals
- No App Clip target now (the layout merely does not prevent adding one later).
- No real backend, no real charge, no accounts, no order history, no persistence across launches.
- No scenario picker (failed / pending / timeout) — that stays in the Example app.
- No shipping address and no full-mode billing address (see §5).
- No new SDK API, no SDK behavior change.

Anti-goals
- Becoming a second playground with many settings. If a screen needs explaining, it is too complex.
- Depending on `SunbayCheckoutTestSupport` (its header says not for production; the Showcase may
  be distributed externally).

## 3. Approaches considered

A. Extend `Example/SunbayCheckoutDemo` with a "showcase" tab. Rejected: mixes two audiences, ships
   developer knobs to customers, and couples release concerns to the dev sandbox.
B. Separate top-level `Showcase/` Tuist project, SwiftUI, own tiny mock services. **Chosen** (user
   agreed on the top-level directory).
C. Separate repository. Rejected for now: the SDK would need a remote package reference and every
   SDK change would need a version bump to be shown. The local-package-path wiring in B keeps this
   option open.

## 4. Structure

```
Showcase/
  Project.swift        # Tuist manifest; local package ../.. ; product SunbayCheckout only
  README.md            # build / run / TestFlight notes (English)
  App/                 # @main entry only (thin)
  Shared/
    Model/             # Product, CartStore, Order (in-memory)
    Theme/             # MerchantTheme, ThemeStore -> SwiftUI colors + SDK Appearance
    Strings/           # Strings (EN/zh) + LanguageStore
    Mock/              # ShowcasePaymentService, ShowcaseCofService (public protocols only)
    Screens/           # ShopView, CartView, ResultView, SettingsSheet
    Checkout/          # CheckoutPresenter: builds SunbayCheckout + presents PaymentSheet
```

All logic lives in `Shared/`; `App/` only holds `@main`, so a future Clip target reuses `Shared/`.
Only the `SunbayCheckout` product is linked; no `SunbayCheckoutTestSupport`.

## 5. Behavior

Flow
1. **Shop**: 5 fixed products (name, price, SF Symbol artwork, no image assets). "Add" increments a
   quantity. Toolbar: cart button with badge, settings button.
2. **Cart**: lines with quantity stepper, total, **Pay** button. Empty cart disables Pay.
3. **Pay**: `CheckoutPresenter` builds `SunbayCheckout` with the theme-derived `Appearance`, the
   current locale, a session whose amount is the cart total, and presents `PaymentSheet` from the
   top view controller (same pattern as the Example app's `PaySheetButton`).
4. **Result** (on `.succeeded`): success mark, order number, amount, and a "Callback" panel showing
   `succeeded(txnId: ...)` and the observed `onStateChange` states in order. "Continue shopping"
   clears the cart and returns to Shop. Other outcomes (cancel; defensively any non-success) return
   to the cart with a short message; the cart is kept.

Theme and language (Settings sheet)
- Appearance: System / Light / Dark.
- Color theme: 3 presets, e.g. Orange (brand, default radius), Blue (sharp radius), Green (round
  radius). Each defines primary color, corner radius, and is applied to merchant UI and to
  `Appearance.colors.primary`, `Appearance.cornerRadius`.
- Mode linkage: the effective merchant mode (System resolved to the current trait collection) is
  passed explicitly as `Appearance.colorScheme = .light/.dark` when presenting, because
  `.automatic` follows the device, not the merchant's override.
- Language: EN / 中文. Drives merchant strings and `CheckoutConfiguration.locale` (`en-US` / `zh-CN`).
- Settings take effect the next time the sheet is presented; no live refresh of an open sheet.

Address (user decision)
- The Showcase does not offer shipping address. It sets `shippingAddressMode` to nothing special and
  adds no shipping UI of its own; billing address stays at the SDK default `.simple`
  (country / line1 / postal code). No address-metadata service is injected (the SDK's fail-soft
  default is used, and `.simple` never calls it).
- Builder to verify on first run that the SDK sheet shows no visible shipping section by default
  (code suggests the shipping section starts hidden). If one appears, report it rather than
  patching the SDK inside this project.

Simulated payments
- `ShowcasePaymentService` implements the public `PaymentService`: `loadSession` returns a
  `CheckoutSession` (amount = cart total, USD, methods card + saved card + Apple Pay, the
  committed demo RSA public key); `submit` waits ~1s then returns a succeeded snapshot with a
  generated demo `txnId`; `getResult` returns the same succeeded snapshot.
- `ShowcaseCofService` returns 2 fixed saved cards so the one-tap saved-card path can be shown.
- Apple Pay row: shown by the SDK only when the device can pay and a merchant id is configured. The
  Showcase passes the same placeholder merchant id as the Example app, overridable via the same
  Tuist env var; the card flow is the guaranteed demo path.

## 6. Constraints (from AGENTS.md)

- Swift only; all code, comments, strings in source, tests, docs in English. The Chinese UI strings
  are a localization table (`Strings`), the only place with non-ASCII text; this is a product
  localization resource, not code commentary. (Builder: keep it a single isolated file.)
- Public SDK API only; no `@testable`, no internals.
- Nothing sensitive logged or shown; the callback panel shows txnId and states only.
- No signing material, team id or real merchant id committed; injected via `TUIST_` env vars.
- Do not commit unless asked; no `git add .`.
- iOS 15 minimum, matching the SDK. Generated `*.xcodeproj` / `Derived/` for `Showcase/` are
  git-ignored the same way as the Example app.

## 7. Testing

Verification is by running the app: Tuist-generate, build for an iOS Simulator, walk the flow in
light and dark, each of the 3 themes, both languages. A small unit test target is optional and not
required for the first cut (cart totals and theme-to-Appearance mapping are the only logic).

## 8. Release readiness (not done by the agent)

The project is structured so `Archive` works once the owner sets bundle id, team and merchant id via
env vars. `Showcase/README.md` documents TestFlight internal (leaders) and external (customers)
distribution, the 90-day build expiry, and that App Store Connect upload is done by the owner.

## 9. Left to the builder

Visual design details (spacing, product names and prices, SF Symbols, order-number format), exact
preset hex values and radii, string wording, file names inside the folders above, whether to add the
optional unit tests.

## 10. Open items

None blocking. Decided with the owner: top-level `Showcase/`, EN/中文 switch, no App Clip now, no
shipping address, billing address `.simple`.

## 11. Clarifications (from the builder check; owner's calls marked "call")

- **SwiftUI + UIKit bridge.** `Example/SunbayCheckoutDemo/Sources/DemoRootView.swift` is SwiftUI
  and already contains `PaySheetButton` and a `topViewController()` helper that present the
  public `PaymentSheet` and read `sheet.onStateChange` / `await sheet.present(from:)`. Copy that
  pattern. `Appearance` fields used (`colors.primary`, `cornerRadius`, `colorScheme`) are public
  (`Sources/SunbayCheckout/Public/Appearance.swift`); `UIColor(sunbayHex:)` is public.
- **Navigation (call).** iOS 15 target equal to the SDK, so `NavigationView` (stack style), no
  `NavigationStack`, no `presentationDetents`, no Observation macros (`ObservableObject` only).
  Cart is a pushed screen, Settings is a SwiftUI sheet that is dismissed before Pay can be tapped,
  so the presenter is always the root-most presented controller found by walking
  `presentedViewController`.
- **RSA key (call).** The demo public key lives in `SunbayCheckoutTestSupport` (`DemoRSAKey`). The
  Showcase copies that single public-key string into `Shared/Mock/` (it is a public key whose
  private key was discarded, safe to ship; see its doc comment). It is not a real credential.
- **Mock completeness.** Builder verifies on first run: (a) whether `submit` is followed by
  `getResult` and make both return success, (b) whether the saved-card one-tap path asks for extra
  input and submits through the same `submit`, (c) card validation. (call) Show a small hint on the
  Cart screen: "Demo: use test card 4242 4242 4242 4242, any future date, any CVC" so a customer
  never fails on stage; the mock accepts whatever the SDK's own validation allows.
- **States and ids.** `onStateChange` is a property on `PaymentSheet` (observed via the presenter).
  Capture states into an array for the Result screen; the final outcome is the source of truth for
  success. (call) The order number is generated by the Showcase (e.g. `SB-` plus 6 digits); the
  `txnId` shown is the one the SDK returns.
- **Env vars.** Copy the mechanism in `Example/SunbayCheckoutDemo/Project.swift`:
  `TUIST_SUNBAY_DEMO_MERCHANT_ID` (default `merchant.native.com.sunbay.dev`) and
  `TUIST_SUNBAY_DEMO_DEVELOPMENT_TEAM` (default empty). Showcase uses its own bundle id
  (e.g. `com.sunbay.checkout.showcase`), overridable the same way. The build must succeed with no
  signing material.
- **Localization resources.** The SDK ships its strings as SPM resources (`Package.swift`
  `resources: [.process("Resources/Localizations")]`); builder confirms on first run that
  switching to `zh-CN` renders Chinese in the sheet.
