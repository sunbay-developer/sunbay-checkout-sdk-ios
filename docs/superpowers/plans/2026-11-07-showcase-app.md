# Showcase App Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build `Showcase/`, a polished fake-merchant iOS app (Shop -> Cart -> SDK PaymentSheet -> Result) that demos the SDK with merchant-linked theme, light/dark and EN/中文.

**Architecture:** Standalone Tuist project at repo top level consuming the root Swift package (`SunbayCheckout` product only). All logic in `Shared/`; `App/` is a thin `@main`. SwiftUI (`NavigationView`, `ObservableObject`) bridged to the UIKit `PaymentSheet` exactly like `Example/SunbayCheckoutDemo`'s `PaySheetButton`. Own mock `PaymentService`/`CofService` implementing the SDK's public protocols.

**Tech Stack:** Swift 5.9, SwiftUI, iOS 15, Tuist, XCTest, SunbayCheckout public API.

**Spec:** `docs/superpowers/specs/2026-11-07-showcase-app-design.md`

## Global Constraints

- Work on a branch `feature/showcase-app` (not `main`). Do not commit unless the user asks; never `git add .`. Task "Commit" steps apply only if the user has asked for commits; otherwise skip them.
- English only in code, comments, identifiers, docs, commit messages. The sole exception: Chinese UI strings in the single file `Shared/Strings/Strings.swift`.
- iOS 15 minimum; `NavigationView` (no `NavigationStack`), `ObservableObject` (no Observation), no `presentationDetents`.
- Public SDK API only; no `@testable import SunbayCheckout`; do NOT link `SunbayCheckoutTestSupport`; no SDK source changes.
- No signing material committed. Env vars (copy mechanism from `Example/SunbayCheckoutDemo/Project.swift`): `TUIST_SUNBAY_SHOWCASE_MERCHANT_ID` (default `merchant.com.sunbay.demo`), `TUIST_SUNBAY_SHOWCASE_DEVELOPMENT_TEAM` (default empty). Bundle id `com.sunbay.checkout.showcase`.
- Nothing sensitive is logged or shown; the callback panel shows `txnId` and states only.
- Billing address stays SDK default `.simple`; no shipping UI; do not inject an address-metadata service.
- Generated `Showcase/*.xcodeproj`, `*.xcworkspace`, `Derived/` are git-ignored.

## Review Focus

- Empty cart: Pay is disabled and never opens the sheet (Task 2 test, Task 7).
- User cancels the sheet: cart is kept, no Result screen, a short message shows (Task 6/7).
- Merchant set to System while the device is dark: `Appearance.colorScheme` must be `.dark`, not `.automatic` (Task 4 test).
- Language switched to 中文: `CheckoutConfiguration.locale == "zh-CN"` and every merchant string has a Chinese value (Task 3 test).
- Double-tap on Pay: only one sheet is presented (Task 6).

---

## File Structure

```
Showcase/
  Project.swift
  README.md
  App/ShowcaseApp.swift
  Shared/Model/Product.swift          # Product + fixed catalog
  Shared/Model/CartStore.swift        # in-memory cart, totals, order number
  Shared/Strings/Strings.swift        # EN/zh table + LanguageStore
  Shared/Theme/MerchantTheme.swift    # presets, ThemeStore, Appearance mapping
  Shared/Mock/ShowcaseServices.swift  # ShowcasePaymentService, ShowcaseCofService, demo key
  Shared/Checkout/CheckoutPresenter.swift
  Shared/Screens/{ShopView,CartView,ResultView,SettingsView,RootView}.swift
  Tests/{CartStoreTests,MerchantThemeTests,StringsTests}.swift
```

### Task 1: Scaffold the Tuist project

**Files:**
- Create: `Showcase/Project.swift`, `Showcase/App/ShowcaseApp.swift`
- Modify: `.gitignore`

**Interfaces:**
- Produces: targets `Showcase` (app, sources `App/**`, `Shared/**`) and `ShowcaseTests` (unit tests, sources `Tests/**`, depends on `Showcase`); one shared runnable scheme `Showcase` including tests.

- [ ] **Step 1:** Create `Project.swift` modeled on `Example/SunbayCheckoutDemo/Project.swift`: `.package(path: "..")`, only `.package(product: "SunbayCheckout")`, `deploymentTargets: .iOS("15.0")`, `UILaunchScreen`, Apple Pay entitlement from `TUIST_SUNBAY_SHOWCASE_MERCHANT_ID`, optional `DEVELOPMENT_TEAM`, `automaticSchemesOptions: .disabled`, plus the `ShowcaseTests` target (`.unitTests`).
- [ ] **Step 2:** `ShowcaseApp.swift`: `@main struct ShowcaseApp: App` whose body is `Text("Showcase")` placeholder.
- [ ] **Step 3:** Append to `.gitignore`: `Showcase/*.xcodeproj`, `Showcase/*.xcworkspace`, `Showcase/Derived/`, `Showcase/.build/`.
- [ ] **Step 4:** Run `cd Showcase && tuist generate --no-open && xcodebuild -scheme Showcase -destination 'generic/platform=iOS Simulator' build`. Expected: BUILD SUCCEEDED, with no signing env vars set.

### Task 2: Catalog and cart

**Files:** Create `Shared/Model/Product.swift`, `Shared/Model/CartStore.swift`, `Tests/CartStoreTests.swift`

**Interfaces:**
- Produces:
  - `struct Product: Identifiable, Equatable { let id: String; let nameKey: String; let priceMinor: Int64; let symbol: String }` and `enum Catalog { static let products: [Product] }` (5 items, SF Symbols, USD minor units; `nameKey` indexes `Strings`).
  - `final class CartStore: ObservableObject` with `@Published private(set) var quantities: [String: Int]`, `func add(_ p: Product)`, `func setQuantity(_ p: Product, _ q: Int)` (0 removes), `var lines: [(Product, Int)]`, `var totalMinor: Int64`, `var itemCount: Int`, `var isEmpty: Bool`, `func clear()`, `static func makeOrderNumber() -> String` (`"SB-"` + 6 digits).

- [ ] **Step 1:** Tests: `testAddAccumulatesTotal`, `testSetQuantityZeroRemovesLine`, `testClearEmptiesCart` (`isEmpty == true`, `totalMinor == 0`), `testOrderNumberFormat` (matches `^SB-\d{6}$`).
- [ ] **Step 2:** Run `xcodebuild test -scheme Showcase -destination 'platform=iOS Simulator,name=iPhone 15'` (use any available simulator). Expected: FAIL (types missing).
- [ ] **Step 3:** Implement the types above.
- [ ] **Step 4:** Re-run tests. Expected: PASS.

### Task 3: Strings and language

**Files:** Create `Shared/Strings/Strings.swift`, `Tests/StringsTests.swift`

**Interfaces:**
- Produces: `enum ShowcaseLanguage: String, CaseIterable { case en, zh; var localeCode: String }` (`"en-US"`, `"zh-CN"`); `final class LanguageStore: ObservableObject { @Published var language: ShowcaseLanguage; func t(_ key: String) -> String }`; `enum Strings { static let keys: [String]; static func value(_ key: String, _ lang: ShowcaseLanguage) -> String }`. Includes product names, screen titles, button labels, the 4242 test-card hint, settings labels, result/callback labels.

- [ ] **Step 1:** Tests: `testEveryKeyHasNonEmptyValueInBothLanguages`, `testLocaleCodes` (`en -> "en-US"`, `zh -> "zh-CN"`), `testEveryCatalogNameKeyExists`.
- [ ] **Step 2:** Run tests. Expected: FAIL.
- [ ] **Step 3:** Implement. Keep all Chinese text in this file only.
- [ ] **Step 4:** Run tests. Expected: PASS.

### Task 4: Merchant theme and Appearance mapping

**Files:** Create `Shared/Theme/MerchantTheme.swift`, `Tests/MerchantThemeTests.swift`

**Interfaces:**
- Consumes: `LanguageStore` is not needed here.
- Produces:
  - `enum ThemePreset: CaseIterable { case orange, blue, green; var primaryHex: String; var cornerRadius: CGFloat }` (orange `#ff6000`/10, blue `#2563eb`/3, green `#16a34a`/20).
  - `enum ModeChoice: CaseIterable { case system, light, dark }`.
  - `final class ThemeStore: ObservableObject { @Published var preset: ThemePreset; @Published var mode: ModeChoice; var swiftUIScheme: ColorScheme? ; var primary: Color; var cornerRadius: CGFloat; func appearance(systemIsDark: Bool) -> Appearance }`.
  - `appearance(systemIsDark:)` sets `colors.primary = UIColor(sunbayHex:)`, `cornerRadius`, and `colorScheme` to `.light`/`.dark` always (System resolves via `systemIsDark`; never `.automatic`).

- [ ] **Step 1:** Tests: `testSystemModeDarkDevicePassesDark`, `testSystemModeLightDevicePassesLight`, `testExplicitLightOverridesDarkDevice`, `testPresetMapsPrimaryAndRadius` (compare `appearance.cornerRadius`; `colors.primary != nil`).
- [ ] **Step 2:** Run tests. Expected: FAIL.
- [ ] **Step 3:** Implement.
- [ ] **Step 4:** Run tests. Expected: PASS.

### Task 5: Mock services

**Files:** Create `Shared/Mock/ShowcaseServices.swift`

**Interfaces:**
- Consumes: SDK public protocols `PaymentService`, `CofService` (read their exact requirements in `Sources/SunbayCheckout`), types `CheckoutSession`, `Amount`, `PaymentSnapshot`, `SubmitRequest`, `SavedCard`. Reference the working shapes in `Sources/SunbayCheckoutTestSupport/ScriptablePaymentService.swift` and `ScriptableCofService.swift` (read-only reference; do not import that module).
- Produces: `final class ShowcasePaymentService: PaymentService { init(amountMinor: Int64, sessionId: String) }` — `loadSession` returns a session (USD, methods `[.card, .applePay, .savedCard]`, cofEnabled true, 15-minute expiry, demo RSA public key); `submit` sleeps 1s then returns a `.succeeded` snapshot with `txnId = "txn_" + random 8 chars`; `getResult` returns that same snapshot. `final class ShowcaseCofService: CofService` returns 2 fixed saved cards (visa 4242, mastercard 4444). `enum ShowcaseRSAKey { static let publicKeyBase64: String }` copied from `DemoRSAKey.publicKeyPKCS1Base64`.

- [ ] **Step 1:** Implement, conforming only to public protocols.
- [ ] **Step 2:** Run `xcodebuild ... build`. Expected: BUILD SUCCEEDED.

### Task 6: Checkout presenter

**Files:** Create `Shared/Checkout/CheckoutPresenter.swift`

**Interfaces:**
- Consumes: `ThemeStore.appearance(systemIsDark:)`, `LanguageStore.language.localeCode`, `ShowcasePaymentService`, `ShowcaseCofService`.
- Produces: `struct PaymentResult { let outcome: CheckoutOutcome; let states: [CheckoutPresentationState] }`; `@MainActor final class CheckoutPresenter: ObservableObject { @Published private(set) var isPresenting: Bool; func pay(amountMinor: Int64, theme: ThemeStore, language: LanguageStore, systemIsDark: Bool) async -> PaymentResult? }`.
- `pay` returns `nil` immediately if `isPresenting` (double-tap guard) or no presenter VC is found. Builds `CheckoutConfiguration(environment: .dev, applePayMerchantId: <env-independent placeholder "merchant.com.sunbay.demo">, appearance:, locale:)`, `SunbayCheckout(configuration:paymentService:cofService:)`, `PaymentSheet(checkout:sessionId:customerAccessSecret: "demo_secret")`, records `onStateChange` into an array, `await sheet.present(from:)` on the top controller (walk `presentedViewController`, copy `topViewController()` from `DemoRootView.swift`), resets `isPresenting` after.

- [ ] **Step 1:** Implement.
- [ ] **Step 2:** Build. Expected: BUILD SUCCEEDED.

### Task 7: Screens and root

**Files:** Create `Shared/Screens/{ShopView,CartView,ResultView,SettingsView,RootView}.swift`; modify `App/ShowcaseApp.swift`

**Interfaces:**
- Consumes: `CartStore`, `ThemeStore`, `LanguageStore`, `CheckoutPresenter`, `Catalog`, `PaymentResult`.
- Produces: `RootView` (owns the three stores as `@StateObject`, injects as environment objects, applies `.preferredColorScheme(theme.swiftUIScheme)` and `.tint(theme.primary)`); `ShowcaseApp` body is `RootView()`.

- [ ] **Step 1:** `ShopView`: list of 5 products with symbol, name, price, "Add" button; toolbar cart button with `itemCount` badge pushing `CartView`, and gear opening `SettingsView` as a sheet.
- [ ] **Step 2:** `CartView`: lines with stepper, total, the localized 4242 test-card hint, Pay button disabled when `cart.isEmpty` or `presenter.isPresenting`. On tap: read `@Environment(\.colorScheme) == .dark` as `systemIsDark`, `await presenter.pay(...)`. `.succeeded` -> push `ResultView` with a new order number; any other outcome -> keep cart, show a short localized message (canceled and failure copy).
- [ ] **Step 3:** `ResultView`: success mark, order number, amount, "Callback" panel (monospaced) with `succeeded(txnId: ...)` and the states joined by ` -> `, and "Continue shopping" which calls `cart.clear()` and pops to Shop. Hide the back button so the cart cannot be re-paid.
- [ ] **Step 4:** `SettingsView`: pickers for mode (System/Light/Dark), color theme (3 presets with swatch), language (EN/中文), Done button.
- [ ] **Step 5:** Build and run on a simulator. Walk the flow with card `4242 4242 4242 4242`: add items -> cart -> Pay -> success -> Result shows txnId and states -> Continue shopping -> cart empty. Expected: matches the spec flow.
- [ ] **Step 6:** Verify visually, in light and dark, for each of the 3 presets and both languages (take simulator screenshots): the sheet primary color, corner radius and mode match the merchant; Chinese renders in the sheet and the merchant UI; no visible shipping section in the sheet; billing shows country / line1 / postal code. Report any deviation instead of patching the SDK.

### Task 8: README and final verification

**Files:** Create `Showcase/README.md`

- [ ] **Step 1:** README (English): purpose, `tuist generate`, env vars, run on simulator, Archive/TestFlight notes (internal for leaders, external for customers, 90-day build expiry, upload done by the owner), and that payments are simulated.
- [ ] **Step 2:** Run the full unit tests: `xcodebuild test -scheme Showcase -destination 'platform=iOS Simulator,name=<available>'`. Expected: all PASS.
- [ ] **Step 3:** From the repo root run `swift test`. Expected: still passes (confirms the SDK is untouched). Run `git status` and confirm no files under `Sources/` changed and no generated Showcase artifacts are tracked.

---

## Self-review notes

- Spec coverage: flow (T7), theme+mode linkage (T4, T7), languages (T3, T7), simulated success and callback (T5, T6, T7), cart cleared (T7), address defaults (T6/T7 step 6), no TestSupport dependency (T1), release notes (T8), env vars (T1). App Clip, persistence, scenarios are non-goals.
- Names match across tasks: `ThemeStore.appearance(systemIsDark:)`, `LanguageStore.language.localeCode`, `PaymentResult`, `CheckoutPresenter.pay`.
- Unit tests cover only the real logic (cart, strings, theme mapping); UI and SDK integration are verified by running the app.
