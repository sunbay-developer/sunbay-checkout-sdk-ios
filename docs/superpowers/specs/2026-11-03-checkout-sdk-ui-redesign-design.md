# Checkout SDK UI Layer Redesign — Design

Status: Draft for review
Date: 2026-11-03
Scope: `Sources/SunbayCheckout/UI/*`, `Sources/SunbayCheckout/Public/Appearance.swift`,
`Sources/SunbayCheckout/Public/CheckoutConfiguration.swift`, new Core address-metadata
protocol, localization resources. Core payment logic is unchanged.

---

## 1. Intent and success criteria

Rebuild the SDK's UI layer to match the new visual design in
`docs/design/checkout-sdk-ui/` (prototype HTML + light/dark exports), while:

1. **Theming + dark/light + merchant customization** — wire the public `Appearance`
   (today an inert data bag) into every view; support light / dark / follow-system and
   merchant-supplied colors, corner radius, border, shadow, font, density, express
   position.
2. **Component separation for reuse** — split a reusable, host-agnostic *content* layer
   from the *container* layer so the same payment UI can be hosted as a bottom sheet now
   (L1) and embedded inline later (L2, v2) with zero rework, mirroring the JS SDK.
3. **Align to Stripe's architecture** where it fits our scenario (nested `Appearance`,
   a `ConfirmButton` state carrier, content↔container split via a delegate, in-sheet
   result states), subtracting the complexity we do not need (multi-method form factory,
   multiple entry points, SPI gating) and adding what our scenario requires (express
   position, density, in-sheet failure block, COF + consent, RSA boundary, i18n,
   dynamic backend-driven address).

**This phase focuses on the UI layer's functionality and API only.** The dynamic address
subsystem is built to its protocol + UI + cache, but **does not consume real data this
phase** — real data wiring comes later. (Backend `/address/*` endpoints already exist.)

Non-goals this phase: L2 embedded container (reserved), Google address autocomplete,
postal-code→state lookup, real backend data wiring.

### Hard constraints carried from AGENTS.md / product-spec

- Swift only; English only inside the repo (code, comments, docs, strings, tests).
- Core stays UI-agnostic: `CheckoutController` and Core import no UIKit/PassKit UI types;
  they depend on protocols only. This is what keeps L2 a zero-rework addition.
- Sensitive-data boundary stays cohesive: only `CardEncryptor` touches plaintext card
  data; only `CredentialStore` holds secrets; nothing sensitive is logged/persisted.
- Backend contract is not final: anything backend-facing sits behind a protocol so the
  mock/demo double can be swapped for the real adapter without touching Core/UI.
- First release ships L1 (PaymentSheet) + L3 (ApplePayButton); L2 reserved for v2.

### Guiding principle (applies throughout)

**Capability free-control, default self-adaptation, graceful downgrade on older OS.**
High OS versions use the full capability (adaptive sheet height, dynamic colors, modern
PassKit button styles); iOS 15 falls back to an equivalent that never crashes or blocks
the main flow.

---

## 2. Architecture overview

Three layers, one-way dependency `Container → Content → Theme`; the content layer reports
back only through a delegate protocol (it never depends on the container). Core is
untouched and unaware of the UI.

```
Host (ISV) → PaymentSheet / ApplePayButton (public)
                │
        Container layer (how it is hosted)
          PaymentSheetContainerViewController (bottom sheet, L1)
          [EmbeddedPaymentElementContainerView reserved, L2/v2]
                │  implements CheckoutContentDelegate
        Content layer (host-agnostic, reusable)
          CheckoutContentViewController (owns the visible state machine)
            CardFormView / SavedCardListView / ExpressCheckoutView /
            ConfirmButton / InlineNoticeView / SimpleAddressFormView /
            DynamicAddressFormView / CheckoutFooterView
                │  reads ResolvedAppearance (injected)       │ reaches Core only via:
        Theme layer                                          │  - PaymentSheet.runCheckout seam → CheckoutController
          ResolvedAppearance / ColorHex / AppearanceDefaults │  - injected AddressMetadataService (protocol)
```

### Directory structure

```
Sources/SunbayCheckout/UI/
├── Theme/
│   ├── ResolvedAppearance.swift        # Appearance → UIColor/CGFloat/UIFont (non-optional, injected)
│   ├── ColorHex.swift                  # "#RRGGBB"/"#RRGGBBAA" → UIColor, tolerant; invalid → semantic default
│   └── AppearanceDefaults.swift        # built-in paired light/dark brand tokens + semantic mapping
├── Content/
│   ├── CheckoutContentViewController.swift
│   ├── CheckoutContentDelegate.swift
│   ├── CheckoutViewState.swift         # editing / processing / succeeded / failed(reason)
│   └── Components/
│       ├── CardFormView.swift
│       ├── SavedCardListView.swift
│       ├── SavedCardRow.swift
│       ├── ExpressCheckoutView.swift   # PKPaymentButton + "Or pay using" divider
│       ├── ConfirmButton.swift         # enabled/disabled/processing/succeeded(ring→check)
│       ├── InlineNoticeView.swift      # severity .error (danger block) / .info (neutral)
│       ├── SimpleAddressFormView.swift # 3 fields: country / line1 / postalCode
│       ├── DynamicAddressFormView.swift# backend-layout-driven (reserved, UI + protocol built)
│       ├── AddressFormLayoutResolver.swift # pure fn: fields+layout → render plan (unit-testable)
│       ├── CheckoutFooterView.swift    # lock + "Powered by SUNBAY"
│       └── SheetHeaderView.swift       # ‹ back + title + ✕
├── Container/
│   └── PaymentSheetContainerViewController.swift
├── PaymentSheet/PaymentSheet.swift     # public L1 entry (API unchanged; internals rebuilt)
├── CardField/CardFieldSecurity.swift   # PCI keyboard/autofill hardening (retained, reused)
├── Wallet/ApplePayButton.swift         # public L3 (API unchanged; renders PKPaymentButton)
├── Wallet/WalletAuthorizerPassKit.swift / WebAuthOpener.swift (retained)
└── Embedded/EmbeddedPaymentElement.swift # empty placeholder (v2)

Sources/SunbayCheckout/Core/
└── AddressMetadata/
    ├── AddressMetadataService.swift    # protocol + models (no UIKit; URLSession adapter ok)
    ├── AddressMetadataModels.swift     # AddressCountry / AddressCountryConfig / AddressFieldConfig / AddressSubdivision / AddressFieldType / AddressInput
    ├── AddressMetadataCache.swift      # in-memory TTL cache + in-flight dedup, key includes locale
    └── HTTPAddressMetadataService.swift# thin adapter, baseURL injected by host (not wired this phase)
```

`CardField/CardField.swift` is absorbed into `CardFormView` (its `cardInput` assembly moves
in); `CardFieldSecurity` is retained and remains the single PCI hardening point.
`PaymentSheetViewController.swift` is removed; its responsibilities split into
`CheckoutContentViewController` (render + state machine) and
`PaymentSheetContainerViewController` (hosting).

---

## 3. Content state machine and delegate

### 3.1 Visible state (internal)

```swift
enum CheckoutViewState: Sendable, Equatable {
    case editing              // choosing method / filling the form; fully interactive
    case processing           // confirm in flight; form disabled, CTA spinner, dismissal blocked
    case succeeded            // CTA ring→checkmark animation, then auto-close
    case failed(reason: String) // inline alert above CTA; sheet stays open and re-editable
}
```

- **Field-level errors are NOT part of this state machine.** Card number / expiry / CVC
  validation errors are `CardFormView`'s own internal state (per-group red border + label),
  matching Stripe's element-level vs payment-level separation. Design screen 4 (field
  error) is rendered by `CardFormView`; screen 7 (payment failed) by `.failed` +
  `InlineNoticeView(.error)`.
- **`pending` / `unknown` are not visible states.** On receiving them the content returns
  to `.editing` and shows a neutral one-line notice via `InlineNoticeView(.info)`; no
  auto-close. Reconciliation remains the host's job via `retrievePayment()`.
- State changes happen on the main thread, one-way:
  `editing → processing → (succeeded | failed)`; `failed` and the notice can return to
  `editing` for retry; `succeeded` is terminal and triggers auto-close.

### 3.2 Transition timeline (aligned to Stripe)

```
tap CTA / select saved card / Apple Pay authorized
  → state = .processing  (disable form; CTA spinner; delegate.didChangeProcessing(true) → container blocks dismissal)
  → delegate.content(didRequest: .confirmNewCard/.confirmSavedCard/.confirmWallet)
container/PaymentSheet drives CheckoutController.confirm* → CheckoutOutcome
  (processing shown ≥ minimumFlightTime to avoid flicker)
  → content.applyOutcome:
      .succeeded → .succeeded (ring→check) → after successDisplayDuration → delegate.didFinishWith(.succeeded)
      .failed    → .failed(reason: error.localizedDisplayMessage); stay open; error haptic + a11y announce
      .pending/.unknown → .editing + InlineNoticeView(.info)
```

The content never calls `CheckoutController` directly; it only emits a requested action
via the delegate, and the existing `PaymentSheet.runCheckout` seam drives the controller
and feeds the outcome back via `applyOutcome`. Single-active/idempotency guarantees are
unchanged.

### 3.3 Delegate

```swift
@MainActor
protocol CheckoutContentDelegate: AnyObject {
    func content(_ c: CheckoutContentViewController, didRequest action: PaymentSheet.UserAction)
    func contentDidRequestCancel(_ c: CheckoutContentViewController)
    func content(_ c: CheckoutContentViewController, didFinishWith outcome: CheckoutOutcome)
    func content(_ c: CheckoutContentViewController, didChangeProcessing isProcessing: Bool)
    func content(_ c: CheckoutContentViewController, didUpdateContentHeight height: CGFloat) // reserved for L2 embedded
    func content(_ c: CheckoutContentViewController, didChangeState state: CheckoutPresentationState) // → public onStateChange
}
```

- `didRequest` reuses the existing `PaymentSheet.UserAction` vocabulary, so `runCheckout`
  barely changes.
- `didUpdateContentHeight` drives the custom bottom sheet's explicit height (see §6.1); the
  future embedded container animates its own height with it — this is the zero-rework
  seam for L2.
- `didChangeProcessing` → the container blocks backdrop-tap / Escape cancels while a confirm is
  in flight (Stripe's `isDismissable`).
- `didChangeState` → mapped to a public `CheckoutPresentationState` and surfaced on
  `PaymentSheet.onStateChange`.

### 3.4 Minimal public additions

```swift
public enum CheckoutPresentationState: Sendable { case editing, processing, succeeded, failed }
// PaymentSheet:
public var onStateChange: ((CheckoutPresentationState) -> Void)? // default nil; does not change auto-close
```

`present(from:) async -> CheckoutOutcome` signature is unchanged. `runCheckout` is extended
to support a retry loop (failed → retry) while keeping single-active/idempotency per confirm.

---

## 4. Theme layer

### 4.1 Public `Appearance` (Stripe-style nested; replaces the flat String? struct)

Placed under `#if canImport(UIKit)`; `CheckoutConfiguration.appearance` is `#if`-wrapped
accordingly (Core does not consume appearance).

```swift
public struct Appearance: Sendable, Equatable {
    public static let `default` = Appearance()
    public init() {}

    public var colors: Colors = .init()
    public var font: Font = .init()
    public var primaryButton: PrimaryButton = .init()
    public var cornerRadius: CGFloat = 10          // matches design
    public var borderWidth: CGFloat = 1            // 0 → borderless (hairline divider)
    public var shadow: Shadow = .none
    public var colorScheme: ColorScheme = .automatic // drives overrideUserInterfaceStyle
    public var density: Density = .comfortable
    public var expressPosition: ExpressPosition = .top
    public var billingAddressMode: AddressCollectionMode = .simple
    public var shippingAddressMode: AddressCollectionMode = .simple

    public enum ColorScheme: Sendable { case light, dark, automatic }
    public enum Density: Sendable { case comfortable, compact }
    public enum ExpressPosition: Sendable { case top, bottom, off }
    public enum AddressCollectionMode: Sendable { case simple, full }

    public struct Colors: Sendable, Equatable {
        public init() {}
        public var primary: UIColor?             // nil → built-in orange (#ff6000 light / adjusted dark)
        public var background: UIColor?          // nil → .systemBackground
        public var componentBackground: UIColor? // nil → semantic field color
        public var text: UIColor?                // nil → .label
        public var textSecondary: UIColor?       // nil → .secondaryLabel
        public var border: UIColor?              // nil → semantic border
        public var danger: UIColor?              // nil → built-in danger (#e5484d / #ff6369)
        public var success: UIColor?             // nil → built-in success (#16a34a / #3dd68c)
    }
    public struct Font: Sendable, Equatable {
        public init() {}
        public var base: UIFont?                 // nil → system font
        public var sizeScaleFactor: CGFloat = 1.0
    }
    public struct PrimaryButton: Sendable, Equatable {
        public init() {}
        public var backgroundColor: UIColor?     // nil → colors.primary
        public var textColor: UIColor?           // nil → white (contrast-checked)
        public var cornerRadius: CGFloat?        // nil → inherits Appearance.cornerRadius
    }
    public struct Shadow: Sendable, Equatable {
        public let color: UIColor; public let opacity: Float
        public let offset: CGSize; public let radius: CGFloat
        public static let none = Shadow(color: .clear, opacity: 0, offset: .zero, radius: 0)
        public static let soft = Shadow(color: .black, opacity: 0.08, offset: .init(width: 0, height: 1), radius: 2)
        public static let medium = Shadow(color: .black, opacity: 0.14, offset: .init(width: 0, height: 3), radius: 10)
    }
}
```

A convenience `UIColor(sunbayHex:)` is provided for hex-oriented merchants and internal
defaults. This is a breaking change vs the old flat `Appearance` — acceptable pre-release;
docs updated accordingly.

### 4.2 `ResolvedAppearance` (internal, pure data, unit-testable)

`Appearance` (optional, semantic defaults) → fully non-optional concrete values
(`UIColor`/`CGFloat`/`UIFont`) injected into each component via init. Components do not
read `Appearance` themselves. `ResolvedAppearance.resolve(_:)` is a pure function.

### 4.3 Dark/light strategy

1. Built-in defaults are all dynamic `UIColor`: structural colors use system semantics
   (`.systemBackground`/`.label`/`.secondaryLabel`/`.separator`); brand/danger/success use
   `UIColor { trait in light/dark }` paired values from the design tokens.
2. A merchant-supplied single `UIColor` is used in both modes (unless the merchant passes a
   dynamic `UIColor`) — matches Stripe.
3. `colorScheme` drives `overrideUserInterfaceStyle` on the container root and content root
   (`.automatic`→`.unspecified`, `.light`/`.dark` lock).
4. `ColorHex` invalid input → fall back to the semantic default (+ `assertionFailure` in
   debug); never crash in production.
5. `CALayer.borderColor` / `shadowColor` (cgColor-based) are reset in
   `traitCollectionDidChange` so dynamic colors refresh on scheme change (known UIKit gap).

---

## 5. Components

- **CardFormView** — grouped card input (design 3/4): card number row (with brand/error
  icon), divider, `MM/YY | CVC` row; group border + optional shadow; group turns red +
  field error label on invalid (field-error layer). Reuses `CardFieldSecurity` for PCI
  hardening. Produces `CardInput?` only (plaintext never logged/persisted). Light
  formatting: 4-digit grouping, auto `/` in expiry, CVC length cap, major-brand prefix for
  the card icon (no large brand DB).
- **SavedCardListView / SavedCardRow** — design 2: "Saved" title + radio rows (selected =
  orange border + tint), brand badge + `•••• 4242` + `08/28`. From `SavedCard`
  (brand/last4/expMonth/expYear). Emits `onSelect(id)` (selection only; Pay submits). The
  "New card" row (`›`) is NOT part of this view: it is a standalone entry row on the home
  page (shown even with no saved cards) that opens the new-card subpage.
- **ExpressCheckoutView** — official `PKPaymentButton` + "Or pay using" divider; position by
  `expressPosition` (.top/.bottom/.off); shown only when `session.methods` has Apple Pay and
  the device is capable. Tap → PassKit authorize (existing `WalletAuthorizer`) → token →
  `.confirmWallet(token:)`. Fixes the current placeholder that reported `.cancel`.
- **ConfirmButton** — status carrier `enabled / disabled / processing / succeeded`; orange
  CTA with localized amount (first use of `AmountFormatter` in the UI); `processing` =
  spinner + "Processing"; `succeeded` = ring→checkmark (ported from Stripe `animateSuccess`),
  completion triggers auto-close; `minimumFlightTime` prevents flicker.
- **InlineNoticeView** — one component, two severities: `.error` (design-7 red alert block,
  above the CTA, from `CheckoutError.localizedDisplayMessage`, error haptic + a11y) and
  `.info` (neutral, for pending/unknown).
- **SimpleAddressFormView** — exactly 3 fields: Country (local system list), Address (line1),
  Postal code. No linkage/dynamic filtering. Submits only country / line1 / postalCode.
  Default mode; zero network.
- **DynamicAddressFormView** — full mode, backend-layout driven (reserved; UI + protocol
  built, no real data this phase): renders by `layout` rows, rebuilds on country change,
  subdivisions dropdown, pattern validation, loading skeleton + error/retry — behavior
  aligned to web `AddressForm.tsx`. No Google autocomplete / postal→state lookup.
- **AddressFormLayoutResolver** — pure function `(fields, layout, collectName) → render plan`,
  unit-testable without UIKit.
- **CheckoutFooterView** — lock + "Powered by SUNBAY" (textSecondary).
- **SheetHeaderView** — `‹` back (new-card subpage only) + centered title
  (`Pay {merchant}` / `New card`) + `✕`.

All components are plain `UIView`s (except card text controls), take `ResolvedAppearance` +
`localize` via init, report via closures/delegate, and can be instantiated standalone (for
snapshots and embedded reuse). Both address views produce the same `AddressInput` (simple
mode fills only the 3 fields). Shipping reuses the same view + "Shipping same as billing"
toggle.

### 5.1 List ↔ new-card navigation (option A, Stripe-style self-managed)

Single content VC switches between the home page (express · saved cards · "New card" entry
row; always the root, even with no saved cards) and the independent new-card subpage,
self-manages the `‹` back; it does NOT embed a `UINavigationController`. The system edge-swipe back gesture does not exist in a
modal sheet, so nothing is lost. Dismissal is a backdrop tap or the ✕ (no pull-down): `editing` →
cancel (`.canceled`); `processing` / `succeeded` → blocked; a backdrop tap on the new-card subpage
closes the whole sheet (cancel), while `‹` is page-level back.

---

## 6. Container layer and L2 reservation

### 6.1 PaymentSheetContainerViewController (L1)

- **Custom presentation, Stripe parity** (replaces the system `.pageSheet` / detents, which on
  iOS 26 floats with 8 pt side insets and large system corners and offers no per-sheet opt-out).
  - iPhone (any non-pad/mac/vision idiom): `modalPresentationStyle = .custom` with a retained
    `BottomSheetTransitioningDelegate` → `BottomSheetPresentationController` +
    `BottomSheetPresentationAnimator`. The presented view is full width (leading/trailing on the
    container safe-area guide), pinned to the container bottom (under the home indicator; the content
    adds the bottom safe-area inset itself), top corners only, radius `max(cornerRadius + 12, 14)`
    (design token `--sr`). Own dimming view: black, alpha 0.4. No grabber, no drag-to-dismiss, no
    scaling of the presenting view. The choice is `BottomSheetPresentationStyle.resolve(idiom:)`.
  - Height: an explicit required-priority height constraint = `BottomSheetGeometry.sheetHeight`
    (pure; reuses `SheetSizingMath`) of the content's reported total height against the available
    height (`container − top safe area − keyboard overlap`). `Appearance.sheetSizing` is honored on
    all iOS versions: `.adaptive` = content height, `.fixedFraction(f)` = `f ×` container height,
    `.large` = full available height, `minHeight` floor, `maxHeightFraction` (of container height) a
    hard cap. Re-evaluated, animated with the transition spring (Reduce Motion: no animation), on
    new content height, rotation and keyboard changes.
  - Transition: slide up / down with a spring `UIViewPropertyAnimator` (0.5 s); cross-dissolve when
    Reduce Motion is on. Programmatic `dismiss(animated:)` (success auto-close) uses the same animator.
  - Keyboard: the bottom constant becomes `−overlap` and the available height shrinks by the overlap,
    animated with the keyboard's duration/curve; the form's scroll view uses
    `keyboardDismissMode = .onDrag`, and the focused field is scrolled into view (on focus and after
    the keyboard animation settles).
  - Dismissal: a backdrop tap (and VoiceOver Escape) is a cancel of the whole sheet, allowed only when
    editable — blocked while `processing` and once `succeeded`, and ignored while a transition
    animation runs. It resolves exactly like ✕ (`.canceled`, once).
  - Accessibility: presented view `accessibilityViewIsModal`; the backdrop is not an accessibility
    element (✕ and Escape are the accessible dismissals).
  - iPad / Mac (Catalyst) / visionOS: the system `.formSheet`, `isModalInPresentation = true`;
    outside-tap attempts run the same allowed-or-blocked cancel rule via the presentation delegate.
    `sheetSizing` does not apply there (the system sizes the form sheet).
- `addChild(contentVC)`; container implements `CheckoutContentDelegate`:
  `didRequest` → `runCheckout` seam; `didChangeProcessing` / `didChangeState(.succeeded)` → block
  cancel; cancel (editing) → `.canceled`; `didFinishWith` → dismiss then return outcome;
  `didUpdateContentHeight` → presentation controller height update; `didChangeState` → public
  `onStateChange`.
- Header `SheetHeaderView`. Root `overrideUserInterfaceStyle` from `colorScheme`.

### 6.2 PaymentSheet.present internals (public API unchanged)

```
1. ResolvedAppearance.resolve(configuration.appearance ?? .default)
2. build CheckoutContentViewController(resolved, localize, billing/shippingMode, addressService)
3. wrap in PaymentSheetContainerViewController (set as content delegate)
4. runCheckout(seam:): present container → await content.didRequest (continuation, now multi-round)
5. outcome from CheckoutController → content.applyOutcome(outcome)
     succeeded → animate → didFinishWith → dismiss → return
     failed/notice → stay, allow retry (next seam round) or cancel
6. return final CheckoutOutcome
```

The testable core of `runCheckout` (start → COF decision → seam → confirm dispatch) is kept,
extended to a retry loop; `retrievePayment()` unchanged.

### 6.3 L2 embedded reservation (zero rework)

Content VC depends only on `CheckoutContentDelegate`. L2 later: add
`EmbeddedPaymentElementContainerView: UIView` (same `addChild`/embed, same delegate) that
consumes `didUpdateContentHeight` for its own height animation; `EmbeddedPaymentElement`
(current placeholder) forwards a height-change delegate to the host. Content layer unchanged.

---

## 7. Core↔UI boundary, localization, Apple Pay

### 7.1 Boundary (AGENTS.md compliant)

- Core unchanged, no UIKit. New `AddressMetadataService` protocol lives in Core (pure Swift;
  `URLSession` adapter has no UIKit). UI reaches Core only via the `runCheckout` seam
  (payments) and the injected `AddressMetadataService` (address metadata, public data).
- Sensitive boundary unchanged: plaintext card only via `CardFormView → CardInput →
  CardEncryptor`; `AddressInput` carries no sensitive payment data; address metadata is
  public. `Appearance`/`ResolvedAppearance` touch nothing sensitive.

### 7.2 Localization (en + zh-Hans in sync)

All visible copy goes through `localize`; `CardField`'s hardcoded English placeholders are
moved into the strings tables. New keys (grouped): sheet structure, card form, field errors,
CTA/state, address (simple + structural), COF. Amount/merchant use `AmountFormatter` +
placeholder strings (`Pay %@`). **Full-mode address label/placeholder/country/subdivision
names come from the backend config (already localized), not our `.strings`;** simple mode and
structural copy use `.strings`. `LocalizationResolver` mechanism is unchanged — only keys are
added. `zh-Hans` translated for every new key.

### 7.3 Locale change refresh (full-mode address)

Effective locale = explicit `configuration.locale` > system preferred > `en-US` (reusing
`LocalizationResolver` order), passed as the `locale` parameter to `AddressMetadataService`.
- Per presentation, locale is fixed at construction for the initial fetch.
- Runtime language change (`NSCurrentLocaleDidChange` / foreground / trait change): if the
  effective locale changed, refetch `countries` + the selected country's `countryConfig`
  with the new locale and rebuild fields, preserving already-entered values (stored as codes:
  country code, line1, postalCode, subdivision code — names are display-only).
- `AddressMetadataCache` key is `(resource, countryCode?, locale)`, so languages are cached
  separately and stale-language data is never shown; in-flight dedup uses the same key.
- Simple mode is unaffected (its labels come from our `.strings`; country names via system
  `Locale`).

### 7.4 Apple Pay PKPaymentButton

- L3 `ApplePayButton` keeps its public API (`init`, `onResult`, `onAvailabilityChange`,
  `isAvailable`, `ApplePayButtonStyle`); internally renders an official `PKPaymentButton`
  subview. `style` maps to `PKPaymentButtonStyle` (`.black`→`.black`, `.white`→
  `.white`/`.whiteOutline`, `.automatic`→by trait, downgrading to `.black`/`.white` on old
  OS). Three-factor availability logic unchanged.
- L1 express row uses `PKPaymentButton` too; tap → real PassKit authorize → `.confirmWallet`.
- Button type `.plain`/`.buy` per design; PassKit localizes the button label.

### 7.5 Address metadata contract (aligned to existing checkout `/address/*`)

```swift
protocol AddressMetadataService: Sendable {
    func countries(locale: String?) async throws -> AddressCountryList          // { countries:[{code,name}], detectedCountry? }
    func countryConfig(countryCode: String, locale: String?) async throws -> AddressCountryConfig
}
// AddressCountryConfig { code, fields:[type: {type,required,pattern?,label,placeholder}], layout:[[AddressFieldType]], subdivisions:[{code,name}] }
// AddressFieldType: country/line1/line2/city/state/postalCode/district/firstName/lastName
```

Injected like `PaymentService`/`CofService` via
`SunbayCheckout(configuration:paymentService:cofService:addressMetadataService:)`.
`HTTPAddressMetadataService` is a thin `URLSession` adapter with host-injected baseURL;
**not wired to real data this phase** — demo/tests use an injected mock double. Contract is
1:1 with the existing web responses, so swapping in the real adapter later needs no Core/UI
change.

---

## 8. Testing strategy

Host `swift test` (no UIKit) — must pass:
- `ResolvedAppearance.resolve` (defaults, single-layer override, hex fallback, radius/
  border/shadow/density/expressPosition).
- `ColorHex` (valid/invalid/alpha/case).
- `AddressMetadataService` contract + `AddressMetadataCache` (hit/expiry, in-flight dedup,
  **key includes locale**, locale change triggers a new request).
- `AddressFormLayoutResolver` (fields+layout → render plan, required/pattern).
- `CheckoutViewState` transitions (editing→processing→succeeded/failed/notice, retry back to
  editing, succeeded terminal) — state machine extracted as pure logic.
- `runCheckout` retry loop keeps single-active/idempotency (reuse + new retry cases).
- Localization: new keys exist in both en and zh-Hans; title-goes-through-localize assertions
  migrated from the old VC's `renderedTitles` to the new content VC.
- Locale-change full-mode address: refetch with new locale + field copy updates + entered
  values preserved (via injected mock service).

UIKit view layer (`#if canImport(UIKit)`, iOS simulator target; skipped under host
`swift test`): components instantiate, `apply(ResolvedAppearance)` doesn't crash, scheme
change refreshes `CALayer.borderColor`/`shadowColor`.

Snapshot tests: a small set over key screens (home / saved / new-card / error / processing /
success), **optional, NOT part of the `swift test` gate**.

Release gates (AGENTS.md §4): `swift test` passes; Apple Pay real-device probe + demo app
(COF, full new-UI flow, dark/light, simple/full address) are pre-release manual verification.
Per AGENTS.md: do not add tests beyond what is asked; when changing tested logic, update its
tests.

---

## 9. Controlled deviations from the design / web (for traceability)

1. Failure state structure follows Stripe (inline area above CTA, retryable); visual reuses
   design screen-7 red alert block styling.
2. Apple Pay uses official `PKPaymentButton` (compliance), not a pixel-exact self-drawn button.
3. Simple address = 3 fields (country/line1/postalCode), no linkage; full mode is the
   backend-driven dynamic renderer.
4. Full mode this phase: protocol + UI + cache built, **no real data wiring**; no Google
   autocomplete, no postal→state lookup.
5. Collection mode (simple/full) is decided by SDK configuration; the backend only decides
   whether each of the two addresses is collected.
6. Height: custom presentation with an explicit height on all iOS versions (15+); no system
   detents (see §6.1).
7. `Appearance` breaking refactor (flat `String?` → Stripe-style nested `UIColor`/`CGFloat`,
   under `#if canImport(UIKit)`) — pre-release; docs updated.
8. In-sheet result states (processing/success/failed/field-error) are new; previously all
   terminal states were returned to the host as `CheckoutOutcome` after dismissal.
9. The design-export grab handle is intentionally NOT shown: the sheet has no drag gesture, which
   matches Stripe.
10. iPad / Mac / visionOS use the system form sheet, like Stripe, instead of the bottom sheet.
11. No pull-down-to-dismiss on iPhone: dismissal is a backdrop tap or ✕ only, and `processing` /
    `succeeded` block dismissal.
