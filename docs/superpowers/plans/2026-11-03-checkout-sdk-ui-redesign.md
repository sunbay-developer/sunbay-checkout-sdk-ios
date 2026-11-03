# Checkout SDK UI Layer Redesign Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Rebuild the SDK's UI layer to match the new design with dark/light theming, merchant-customizable `Appearance`, an in-sheet payment state machine, and a reusable content/container split that makes L2 embedded a zero-rework addition.

**Architecture:** Three layers with one-way dependency `Container → Content → Theme`; the content layer reports back only via `CheckoutContentDelegate`. Core payment logic is untouched; UI reaches Core only through the existing `PaymentSheet.runCheckout` seam and a new injected `AddressMetadataService` protocol. Aligned to Stripe (nested Appearance, `ConfirmButton` state carrier, content↔container delegate) with our-scenario subtractions and additions.

**Tech Stack:** Swift, UIKit (programmatic), PassKit (`PKPaymentButton`), Swift Concurrency, XCTest, Swift Package Manager. iOS 15 minimum.

**Spec:** `docs/superpowers/specs/2026-11-03-checkout-sdk-ui-redesign-design.md`

## Global Constraints

- Swift only; **English only inside the repo** (code, comments, doc comments, identifiers, string literals, test names, commit messages).
- Core imports no UIKit/PassKit UI types; depends on protocols only. New `AddressMetadataService` lives in Core and uses `Foundation`/`URLSession` only (no UIKit).
- Sensitive-data boundary: only `CardEncryptor` touches plaintext card data; only `CredentialStore` holds secrets. `CardFormView` produces `CardInput` and nothing more; plaintext is never logged/persisted. `AddressInput` and address metadata carry no sensitive payment data.
- All UIKit/PassKit UI code is gated `#if canImport(UIKit)`. `Appearance` (contains `UIColor`/`UIFont`) is gated `#if canImport(UIKit)`; `CheckoutConfiguration.appearance` is `#if`-wrapped accordingly.
- Public API to preserve unchanged: `PaymentSheet.present(from:) async -> CheckoutOutcome`, `PaymentSheet.retrievePayment()`, `ApplePayButton` (`init(checkout:sessionId:style:)`, `onResult`, `onAvailabilityChange`, `isAvailable`, `ApplePayButtonStyle`), `CheckoutOutcome`, `CheckoutError`.
- `swift test` must pass. Do not add tests beyond what is asked; when changing tested logic, update its tests.
- New localized copy goes in both `en.lproj` and `zh-Hans.lproj` Localizable.strings; UI copy routes through the injected `localize` closure. Full-mode address label/placeholder/country/subdivision names come from the backend config (not our `.strings`).
- Design tokens (verbatim): brand `#ff6000`; danger `#e5484d` (light) / `#ff6369` (dark); success `#16a34a` (light) / `#3dd68c` (dark); default cornerRadius `10`; default borderWidth `1`.
- Guiding principle: capability free-control, default self-adaptation, graceful downgrade on older OS (iOS 16+ adaptive sheet height via `.custom` + `invalidateDetents()`; iOS 15 → `.medium()/.large()` + internal scroll).
- This phase is UI layer + API only. `AddressMetadataService` is built to protocol + UI + cache; real data is NOT wired (demo/tests use an injected mock double).

## Review Focus

- **Invalid / partial hex color strings** passed to `UIColor(sunbayHex:)` (empty, `"#xyz"`, missing `#`, 7 chars) — must fall back to the semantic default and never crash in production (Task 1).
- **Scheme switch (light↔dark) at runtime** — `CALayer.borderColor`/`shadowColor` are cgColor snapshots and must be re-resolved in `traitCollectionDidChange`, or borders/shadows keep the stale scheme's color (Task 6).
- **Effective-locale change for full-mode address** — must refetch `countryConfig` with the new locale and preserve already-entered values (stored as codes), not show stale-language labels (Task 3, Task 9).
- **Pull-to-dismiss during `processing`** — must be blocked (`isModalInPresentation = true`) so a confirm in flight cannot be interrupted by a gesture (Task 8).
- **`pending` / `unknown` outcome** — must return to `.editing` with a neutral `.info` notice (not a red error, not auto-close), leaving reconciliation to the host (Task 7).

---

### Task 1: Color hex parsing + appearance defaults (Theme primitives)

**Files:**
- Create: `Sources/SunbayCheckout/UI/Theme/ColorHex.swift`
- Create: `Sources/SunbayCheckout/UI/Theme/AppearanceDefaults.swift`
- Test: `Tests/SunbayCheckoutTests/UI/ColorHexTests.swift`

**Interfaces:**
- Consumes: nothing.
- Produces:
  - `extension UIColor { convenience init?(sunbayHex: String) }` — parses `#RGB`, `#RRGGBB`, `#RRGGBBAA` (leading `#` optional, case-insensitive); returns nil on invalid input.
  - `enum AppearanceDefaults` with static dynamic colors: `brandPrimary`, `danger`, `success`, and semantic accessors `background`, `componentBackground`, `text`, `textSecondary`, `border` (all `UIColor`). `brandPrimary`/`danger`/`success` are built with `UIColor { traitCollection in ... }` paired light/dark from the token values; semantics map to `.systemBackground`/`.secondarySystemBackground`/`.label`/`.secondaryLabel`/`.separator`.
- All code `#if canImport(UIKit)`.

- [ ] **Step 1: Write the failing test** in `ColorHexTests.swift`

```swift
func test_parsesSixDigitHex() {
    let c = UIColor(sunbayHex: "#ff6000")
    XCTAssertNotNil(c)
}
func test_parsesWithoutHash_andCaseInsensitive() {
    XCTAssertNotNil(UIColor(sunbayHex: "FF6000"))
}
func test_parsesEightDigitHexWithAlpha() {
    XCTAssertNotNil(UIColor(sunbayHex: "#ff6000cc"))
}
func test_returnsNilOnInvalid() {
    XCTAssertNil(UIColor(sunbayHex: ""))
    XCTAssertNil(UIColor(sunbayHex: "#xyz"))
    XCTAssertNil(UIColor(sunbayHex: "#1234567")) // 7 digits
}
```

- [ ] **Step 2: Run test to verify it fails** — Run: `swift test --filter ColorHexTests` Expected: FAIL (no such initializer). Note: the test file is `#if canImport(UIKit)`; verify on an iOS-capable toolchain/simulator target.

- [ ] **Step 3: Implement** `UIColor(sunbayHex:)` in `ColorHex.swift` and `AppearanceDefaults` in `AppearanceDefaults.swift`. Strip optional leading `#`, normalize length (3→6 by doubling), parse with `Scanner`/`UInt64(_, radix: 16)`; invalid length or parse failure → nil.

- [ ] **Step 4: Run test to verify it passes** — Run: `swift test --filter ColorHexTests` Expected: PASS

- [ ] **Step 5: Commit**

```bash
git add Sources/SunbayCheckout/UI/Theme/ColorHex.swift Sources/SunbayCheckout/UI/Theme/AppearanceDefaults.swift Tests/SunbayCheckoutTests/UI/ColorHexTests.swift
git commit -m "feat(ui): add color hex parsing and appearance default tokens"
```

---

### Task 2: Public `Appearance` rewrite + `ResolvedAppearance`

**Files:**
- Modify (replace): `Sources/SunbayCheckout/Public/Appearance.swift`
- Modify: `Sources/SunbayCheckout/Public/CheckoutConfiguration.swift` (wrap `appearance` in `#if canImport(UIKit)`)
- Create: `Sources/SunbayCheckout/UI/Theme/ResolvedAppearance.swift`
- Test: `Tests/SunbayCheckoutTests/UI/ResolvedAppearanceTests.swift`

**Interfaces:**
- Consumes: `AppearanceDefaults`, `UIColor(sunbayHex:)` (Task 1).
- Produces:
  - `public struct Appearance` with the full nested shape from spec §4.1 (`colors`, `font`, `primaryButton`, `cornerRadius: CGFloat = 10`, `borderWidth: CGFloat = 1`, `shadow: Shadow = .none`, `colorScheme: ColorScheme = .automatic`, `density: Density = .comfortable`, `expressPosition: ExpressPosition = .top`, `billingAddressMode: AddressCollectionMode = .simple`, `shippingAddressMode: AddressCollectionMode = .simple`), nested `Colors/Font/PrimaryButton/Shadow` and enums `ColorScheme/Density/ExpressPosition/AddressCollectionMode`, and `static let default`. All `#if canImport(UIKit)`.
  - `struct ResolvedAppearance` (internal) with non-optional concrete fields from spec §4.2 and `static func resolve(_ appearance: Appearance) -> ResolvedAppearance`.

- [ ] **Step 1: Write the failing test** in `ResolvedAppearanceTests.swift`

```swift
func test_defaultsResolveToTokens() {
    let r = ResolvedAppearance.resolve(.default)
    XCTAssertEqual(r.cornerRadius, 10)
    XCTAssertEqual(r.borderWidth, 1)
    XCTAssertEqual(r.density, .comfortable)
    XCTAssertEqual(r.expressPosition, .top)
}
func test_merchantColorOverridesSingleLayer() {
    var a = Appearance()
    a.colors.primary = UIColor(sunbayHex: "#2563eb")
    let r = ResolvedAppearance.resolve(a)
    XCTAssertEqual(r.primary, UIColor(sunbayHex: "#2563eb"))
}
func test_primaryButtonInheritsAppearanceCornerRadiusWhenNil() {
    var a = Appearance(); a.cornerRadius = 4
    let r = ResolvedAppearance.resolve(a)
    XCTAssertEqual(r.primaryButtonCornerRadius, 4)
}
```

- [ ] **Step 2: Run test to verify it fails** — Run: `swift test --filter ResolvedAppearanceTests` Expected: FAIL (new type / fields).

- [ ] **Step 3: Implement** the `Appearance` rewrite, the `#if` wrap in `CheckoutConfiguration`, and `ResolvedAppearance.resolve` (each field: use the merchant value if present, else the `AppearanceDefaults` value; fonts derive from `font.base` + `sizeScaleFactor` + text styles; `primaryButton*` fall back to `colors.primary` / white / `cornerRadius`).

- [ ] **Step 4: Run test to verify it passes** — Run: `swift test --filter ResolvedAppearanceTests` Expected: PASS

- [ ] **Step 5: Run the full suite** — Run: `swift test` Expected: PASS (confirms removing the old flat `Appearance` fields did not break Core/other tests; fix any references to old field names).

- [ ] **Step 6: Commit**

```bash
git add Sources/SunbayCheckout/Public/Appearance.swift Sources/SunbayCheckout/Public/CheckoutConfiguration.swift Sources/SunbayCheckout/UI/Theme/ResolvedAppearance.swift Tests/SunbayCheckoutTests/UI/ResolvedAppearanceTests.swift
git commit -m "feat(ui): nested Appearance and ResolvedAppearance resolver"
```

---

### Task 3: Address metadata Core protocol + models + cache

**Files:**
- Create: `Sources/SunbayCheckout/Core/AddressMetadata/AddressMetadataModels.swift`
- Create: `Sources/SunbayCheckout/Core/AddressMetadata/AddressMetadataService.swift`
- Create: `Sources/SunbayCheckout/Core/AddressMetadata/AddressMetadataCache.swift`
- Create: `Sources/SunbayCheckout/Core/AddressMetadata/HTTPAddressMetadataService.swift`
- Test: `Tests/SunbayCheckoutTests/Core/AddressMetadataCacheTests.swift`

**Interfaces:**
- Consumes: nothing (Core, Foundation only, no UIKit).
- Produces:
  - `public enum AddressFieldType: String, Sendable { case country, line1, line2, city, state, postalCode, district, firstName, lastName }`
  - `public struct AddressCountry: Sendable, Equatable { let code: String; let name: String }`
  - `public struct AddressSubdivision: Sendable, Equatable { let code: String; let name: String }`
  - `public struct AddressFieldConfig: Sendable, Equatable { let type: AddressFieldType; let required: Bool; let pattern: String?; let label: String; let placeholder: String }`
  - `public struct AddressCountryConfig: Sendable, Equatable { let code: String; let fields: [AddressFieldType: AddressFieldConfig]; let layout: [[AddressFieldType]]; let subdivisions: [AddressSubdivision] }`
  - `public struct AddressCountryList: Sendable, Equatable { let countries: [AddressCountry]; let detectedCountry: String? }`
  - `public struct AddressInput: Sendable, Equatable { var country: String?; var line1: String?; var line2: String?; var city: String?; var state: String?; var postalCode: String?; var district: String?; var firstName: String?; var lastName: String? }`
  - `public protocol AddressMetadataService: Sendable { func countries(locale: String?) async throws -> AddressCountryList; func countryConfig(countryCode: String, locale: String?) async throws -> AddressCountryConfig }`
  - `actor AddressMetadataCache` wrapping any `AddressMetadataService`, keying cached values and in-flight tasks by `(resource, countryCode?, locale)`, with the same two async methods; and `struct HTTPAddressMetadataService: AddressMetadataService` (thin `URLSession` adapter, baseURL injected).

- [ ] **Step 1: Write the failing test** in `AddressMetadataCacheTests.swift` using a spy double conforming to `AddressMetadataService` that counts calls.

```swift
func test_cachesCountryConfigPerLocale() async throws {
    let spy = SpyAddressService() // returns fixed config, counts calls
    let cache = AddressMetadataCache(wrapping: spy)
    _ = try await cache.countryConfig(countryCode: "US", locale: "en")
    _ = try await cache.countryConfig(countryCode: "US", locale: "en")
    XCTAssertEqual(spy.configCallCount, 1) // second served from cache
    _ = try await cache.countryConfig(countryCode: "US", locale: "zh-Hans")
    XCTAssertEqual(spy.configCallCount, 2) // different locale → new request
}
func test_dedupsConcurrentIdenticalRequests() async throws {
    let spy = SpyAddressService(delayMs: 20)
    let cache = AddressMetadataCache(wrapping: spy)
    async let a = cache.countries(locale: "en")
    async let b = cache.countries(locale: "en")
    _ = try await (a, b)
    XCTAssertEqual(spy.countriesCallCount, 1)
}
```

- [ ] **Step 2: Run test to verify it fails** — Run: `swift test --filter AddressMetadataCacheTests` Expected: FAIL (types/actor absent).

- [ ] **Step 3: Implement** the models, protocol, `AddressMetadataCache` (store `[Key: Value]` + `[Key: Task]` for in-flight dedup, TTL optional-but-present field defaulting to 1h), and `HTTPAddressMetadataService` (builds `/address/country` and `/address/country/{code}` URLs with `locale`/`countries` query, decodes JSON via `Codable` DTOs mapping to the models; `fields` JSON object → `[AddressFieldType: AddressFieldConfig]`).

- [ ] **Step 4: Run test to verify it passes** — Run: `swift test --filter AddressMetadataCacheTests` Expected: PASS

- [ ] **Step 5: Commit**

```bash
git add Sources/SunbayCheckout/Core/AddressMetadata Tests/SunbayCheckoutTests/Core/AddressMetadataCacheTests.swift
git commit -m "feat(core): address metadata protocol, models, and caching"
```

---

### Task 4: Checkout view state machine (pure logic)

**Files:**
- Create: `Sources/SunbayCheckout/UI/Content/CheckoutViewState.swift`
- Create: `Sources/SunbayCheckout/UI/Content/CheckoutStateMachine.swift`
- Create: `Sources/SunbayCheckout/Public/CheckoutPresentationState.swift`
- Test: `Tests/SunbayCheckoutTests/UI/CheckoutStateMachineTests.swift`

**Interfaces:**
- Consumes: `CheckoutOutcome` (existing).
- Produces:
  - `enum CheckoutViewState: Sendable, Equatable { case editing, processing, succeeded, case failed(reason: String) }` (internal).
  - `public enum CheckoutPresentationState: Sendable { case editing, processing, succeeded, failed }`.
  - `struct CheckoutStateMachine` with `private(set) var state: CheckoutViewState = .editing`; `mutating func beginProcessing()`; `mutating func apply(_ outcome: CheckoutOutcome, localizedFailure: (CheckoutError) -> String) -> StepResult` where `StepResult` tells the caller whether to auto-close (`.succeeded`), show a `.failed(reason)`, show an `.info` notice (`pending`/`unknown`) and return to editing, or stay (`.canceled`). `var presentationState: CheckoutPresentationState` computed mapping.
- This type is UIKit-free so it runs under host `swift test`.

- [ ] **Step 1: Write the failing test** in `CheckoutStateMachineTests.swift`

```swift
func test_successIsTerminalAndRequestsClose() {
    var m = CheckoutStateMachine(); m.beginProcessing()
    let r = m.apply(.succeeded(txnId: "t1"), localizedFailure: { _ in "" })
    XCTAssertEqual(m.state, .succeeded)
    XCTAssertEqual(r, .autoClose(.succeeded(txnId: "t1")))
}
func test_failedStaysEditableWithReason() {
    var m = CheckoutStateMachine(); m.beginProcessing()
    let err = CheckoutErrorsFixture.paymentFailed() // test fixture
    let r = m.apply(.failed(txnId: nil, error: err), localizedFailure: { _ in "Insufficient funds." })
    XCTAssertEqual(m.state, .failed(reason: "Insufficient funds."))
    XCTAssertEqual(r, .showError("Insufficient funds."))
}
func test_pendingReturnsToEditingWithInfoNotice() {
    var m = CheckoutStateMachine(); m.beginProcessing()
    let r = m.apply(.pending(txnId: nil), localizedFailure: { _ in "" })
    XCTAssertEqual(m.state, .editing)
    XCTAssertEqual(r, .showInfoNotice)
}
func test_unknownReturnsToEditingWithInfoNotice() {
    var m = CheckoutStateMachine(); m.beginProcessing()
    let r = m.apply(.unknown(sessionId: "s1"), localizedFailure: { _ in "" })
    XCTAssertEqual(m.state, .editing)
    XCTAssertEqual(r, .showInfoNotice)
}
```

- [ ] **Step 2: Run test to verify it fails** — Run: `swift test --filter CheckoutStateMachineTests` Expected: FAIL.

- [ ] **Step 3: Implement** `CheckoutViewState`, `CheckoutPresentationState`, and `CheckoutStateMachine` with a `StepResult: Equatable` enum (`autoClose(CheckoutOutcome)`, `showError(String)`, `showInfoNotice`, `stay`). `apply` maps outcomes per spec §3.2.

- [ ] **Step 4: Run test to verify it passes** — Run: `swift test --filter CheckoutStateMachineTests` Expected: PASS

- [ ] **Step 5: Commit**

```bash
git add Sources/SunbayCheckout/UI/Content/CheckoutViewState.swift Sources/SunbayCheckout/UI/Content/CheckoutStateMachine.swift Sources/SunbayCheckout/Public/CheckoutPresentationState.swift Tests/SunbayCheckoutTests/UI/CheckoutStateMachineTests.swift
git commit -m "feat(ui): checkout view state machine"
```

---

### Task 5: Address form layout resolver (pure logic)

**Files:**
- Create: `Sources/SunbayCheckout/UI/Content/Components/AddressFormLayoutResolver.swift`
- Test: `Tests/SunbayCheckoutTests/UI/AddressFormLayoutResolverTests.swift`

**Interfaces:**
- Consumes: `AddressCountryConfig`, `AddressFieldType`, `AddressFieldConfig` (Task 3).
- Produces: `enum AddressFormLayoutResolver { static func renderRows(config: AddressCountryConfig, collectName: Bool) -> [[AddressFieldConfig]] }` — maps `config.layout` rows to resolved field configs, dropping field types absent from `config.fields`, and dropping `firstName`/`lastName` when `collectName == false`; empty rows removed.

- [ ] **Step 1: Write the failing test**

```swift
func test_dropsFieldsNotInConfigAndEmptyRows() {
    let cfg = AddressCountryConfigFixture.us() // layout includes a row with only firstName
    let rows = AddressFormLayoutResolver.renderRows(config: cfg, collectName: false)
    XCTAssertFalse(rows.contains { $0.contains { $0.type == .firstName } })
    XCTAssertFalse(rows.contains { $0.isEmpty })
}
func test_preservesRowGroupingForCityStatePostal() {
    let cfg = AddressCountryConfigFixture.us()
    let rows = AddressFormLayoutResolver.renderRows(config: cfg, collectName: false)
    XCTAssertTrue(rows.contains { $0.map(\.type) == [.city, .state, .postalCode] })
}
```

- [ ] **Step 2: Run test to verify it fails** — Run: `swift test --filter AddressFormLayoutResolverTests` Expected: FAIL.

- [ ] **Step 3: Implement** `renderRows` (filter + map per interface).

- [ ] **Step 4: Run test to verify it passes** — Run: `swift test --filter AddressFormLayoutResolverTests` Expected: PASS

- [ ] **Step 5: Commit**

```bash
git add Sources/SunbayCheckout/UI/Content/Components/AddressFormLayoutResolver.swift Tests/SunbayCheckoutTests/UI/AddressFormLayoutResolverTests.swift
git commit -m "feat(ui): address form layout resolver"
```

---

### Task 6: Themeable base view + ConfirmButton + InlineNoticeView

**Files:**
- Create: `Sources/SunbayCheckout/UI/Content/Components/ThemeableView.swift`
- Create: `Sources/SunbayCheckout/UI/Content/Components/ConfirmButton.swift`
- Create: `Sources/SunbayCheckout/UI/Content/Components/InlineNoticeView.swift`
- Test: `Tests/SunbayCheckoutTests/UI/ConfirmButtonTests.swift`

**Interfaces:**
- Consumes: `ResolvedAppearance` (Task 2).
- Produces:
  - A small helper (free function or protocol extension) `applyDynamicLayerColors(_:border:shadow:)` that resets `CALayer.borderColor`/`shadowColor` from `ResolvedAppearance`, to be called from each component's `traitCollectionDidChange`.
  - `final class ConfirmButton: UIControl` with `enum Status { case enabled, disabled, processing, succeeded }`, `init(appearance: ResolvedAppearance)`, `func setTitle(_ title: String)`, `func update(status: Status, animated: Bool, completion: (() -> Void)? = nil)`, `var onTap: (() -> Void)?`, and a static `minimumFlightTime: TimeInterval = 0.5` / `successDisplayDuration: TimeInterval = 0.8`.
  - `final class InlineNoticeView: UIView` with `enum Severity { case error, info }`, `init(appearance: ResolvedAppearance)`, `func show(message: String, severity: Severity)`, `func hide()`.
- All `#if canImport(UIKit)`.

- [ ] **Step 1: Write the failing test** in `ConfirmButtonTests.swift`

```swift
func test_processingDisablesInteraction() {
    let b = ConfirmButton(appearance: .resolve(.default))
    b.update(status: .processing, animated: false)
    XCTAssertFalse(b.isEnabled)
}
func test_succeededInvokesCompletion() {
    let b = ConfirmButton(appearance: .resolve(.default))
    let exp = expectation(description: "done")
    b.update(status: .succeeded, animated: false) { exp.fulfill() }
    wait(for: [exp], timeout: 2)
}
func test_schemeChangeReresolvesLayerColors() {
    // InlineNoticeView uses a CALayer border; after a trait change its
    // borderColor must be re-resolved, not keep the stale scheme's cgColor.
    let v = InlineNoticeView(appearance: .resolve(.default))
    v.show(message: "x", severity: .error)
    let light = UITraitCollection(userInterfaceStyle: .light)
    let dark = UITraitCollection(userInterfaceStyle: .dark)
    v.overrideUserInterfaceStyle = .light; v.traitCollectionDidChangeForTest(light)
    let lightColor = v.layer.borderColor
    v.overrideUserInterfaceStyle = .dark; v.traitCollectionDidChangeForTest(dark)
    XCTAssertNotEqual(lightColor, v.layer.borderColor)
}
```

Note: `traitCollectionDidChangeForTest` is a thin test seam calling the same
`applyDynamicLayerColors` path used by the real `traitCollectionDidChange`.

- [ ] **Step 2: Run test to verify it fails** — Run: `swift test --filter ConfirmButtonTests` Expected: FAIL.

- [ ] **Step 3: Implement** `ThemeableView` helper, `ConfirmButton` (spinner via `UIActivityIndicatorView`; ring→checkmark via `CAShapeLayer` stroke animation, ported conceptually from Stripe `animateSuccess`; `succeeded` with `animated:false` still calls completion after `successDisplayDuration`), and `InlineNoticeView` (danger block vs neutral styling; error haptic via `UINotificationFeedbackGenerator` on `.error`; `UIAccessibility.post(.layoutChanged)` on show).

- [ ] **Step 4: Run test to verify it passes** — Run: `swift test --filter ConfirmButtonTests` Expected: PASS

- [ ] **Step 5: Commit**

```bash
git add Sources/SunbayCheckout/UI/Content/Components/ThemeableView.swift Sources/SunbayCheckout/UI/Content/Components/ConfirmButton.swift Sources/SunbayCheckout/UI/Content/Components/InlineNoticeView.swift Tests/SunbayCheckoutTests/UI/ConfirmButtonTests.swift
git commit -m "feat(ui): ConfirmButton state carrier and InlineNoticeView"
```

---

### Task 7: Card form, saved-card list, express, address, footer, header views

**Files:**
- Create: `Sources/SunbayCheckout/UI/Content/Components/CardFormView.swift`
- Create: `Sources/SunbayCheckout/UI/Content/Components/SavedCardRow.swift`
- Create: `Sources/SunbayCheckout/UI/Content/Components/SavedCardListView.swift`
- Create: `Sources/SunbayCheckout/UI/Content/Components/ExpressCheckoutView.swift`
- Create: `Sources/SunbayCheckout/UI/Content/Components/SimpleAddressFormView.swift`
- Create: `Sources/SunbayCheckout/UI/Content/Components/DynamicAddressFormView.swift`
- Create: `Sources/SunbayCheckout/UI/Content/Components/CheckoutFooterView.swift`
- Create: `Sources/SunbayCheckout/UI/Content/Components/SheetHeaderView.swift`
- Modify: `Sources/SunbayCheckout/UI/CardField/CardField.swift` (absorb `cardInput` assembly into `CardFormView`; keep or remove file — remove if nothing else references it)
- Keep: `Sources/SunbayCheckout/UI/CardField/CardFieldSecurity.swift` (reused by `CardFormView`)
- Test: `Tests/SunbayCheckoutTests/UI/CardFormViewTests.swift`

**Interfaces:**
- Consumes: `ResolvedAppearance` (Task 2); `CardInput` (existing); `CardFieldSecurity` (existing); `SavedCard` (`id, brand, last4, expMonth, expYear`); `AddressInput`, `AddressMetadataService`, `AddressFormLayoutResolver`, `AddressCountryConfig` (Tasks 3, 5); a `localize: (String) -> String` closure.
- Produces (each `#if canImport(UIKit)`):
  - `final class CardFormView: UIView` — `init(appearance:localize:)`; `var cardInput: CardInput?` (reuses the current trim/split rules); `func showFieldError(_ which: Field, message: String?)`; `var onEditingChanged: (() -> Void)?`.
  - `final class SavedCardRow: UIView` and `final class SavedCardListView: UIView` — `init(appearance:localize:cards:[SavedCard])`; `var onSelect: ((String) -> Void)?`; `var onTapNewCard: (() -> Void)?`; `var selectedPaymentMethodId: String?`.
  - `final class ExpressCheckoutView: UIView` — `init(appearance:)`; `var onApplePayTapped: (() -> Void)?` (renders `PKPaymentButton`).
  - `final class SimpleAddressFormView: UIView` — `init(appearance:localize:)`; `var addressInput: AddressInput` (fills only country/line1/postalCode).
  - `final class DynamicAddressFormView: UIView` — `init(appearance:localize:service:AddressMetadataService, locale:String?)`; `func reload(locale: String?)`; `var addressInput: AddressInput`; shows skeleton/error/retry; rebuilds on country change preserving entered values.
  - `final class CheckoutFooterView: UIView`, `final class SheetHeaderView: UIView` (`var onBack:(()->Void)?; var onClose:(()->Void)?; func setTitle(_:); func setBackVisible(_:)`).

- [ ] **Step 1: Write the failing test** in `CardFormViewTests.swift`

```swift
func test_cardInputNilWhenIncomplete() {
    let v = CardFormView(appearance: .resolve(.default), localize: { $0 })
    XCTAssertNil(v.cardInput)
}
func test_cardInputAssemblesWhenComplete() {
    let v = CardFormView(appearance: .resolve(.default), localize: { $0 })
    v.setFieldsForTest(pan: "4242424242424242", expiry: "08/28", cvv: "123")
    XCTAssertEqual(v.cardInput?.cardNumber, "4242424242424242")
    XCTAssertEqual(v.cardInput?.expiryMonth, "08")
    XCTAssertEqual(v.cardInput?.expiryYear, "28")
}
```

- [ ] **Step 2: Run test to verify it fails** — Run: `swift test --filter CardFormViewTests` Expected: FAIL.

- [ ] **Step 3: Implement** all components. `CardFormView` groups fields per design, calls `CardFieldSecurity.apply`, exposes a test-only `setFieldsForTest`. `DynamicAddressFormView` uses `AddressFormLayoutResolver` + the injected service; values stored as codes so `reload(locale:)` preserves them. `SimpleAddressFormView` is a fixed 3-field form.

- [ ] **Step 4: Run test to verify it passes** — Run: `swift test --filter CardFormViewTests` Expected: PASS

- [ ] **Step 5: Run full suite** — Run: `swift test` Expected: PASS (ensure removing/altering `CardField` did not break anything).

- [ ] **Step 6: Commit**

```bash
git add Sources/SunbayCheckout/UI/Content/Components Sources/SunbayCheckout/UI/CardField Tests/SunbayCheckoutTests/UI/CardFormViewTests.swift
git commit -m "feat(ui): card form, saved cards, express, address, header/footer views"
```

---

### Task 8: Content view controller + delegate (wires components to the state machine)

**Files:**
- Create: `Sources/SunbayCheckout/UI/Content/CheckoutContentDelegate.swift`
- Create: `Sources/SunbayCheckout/UI/Content/CheckoutContentViewController.swift`
- Test: `Tests/SunbayCheckoutTests/UI/CheckoutContentViewControllerTests.swift`

**Interfaces:**
- Consumes: all Task 6/7 components; `CheckoutStateMachine` (Task 4); `ResolvedAppearance`; `PaymentSheet.UserAction` (existing internal enum); `CheckoutSession`, `SavedCard`, `CheckoutOutcome`, `CheckoutError`; `Appearance.AddressCollectionMode`.
- Produces:
  - `@MainActor protocol CheckoutContentDelegate: AnyObject { ... }` exactly as spec §3.3 (six methods).
  - `final class CheckoutContentViewController: UIViewController` — `init(session:savedCards:appearance:localize:billingMode:shippingMode:addressService:)`; `weak var delegate: CheckoutContentDelegate?`; `func applyOutcome(_ outcome: CheckoutOutcome)`; manages list↔new-card sub-view switching and the state machine; a test-only `func simulateTapPay()` / readout of current `CheckoutViewState`.
- `#if canImport(UIKit)`.

- [ ] **Step 1: Write the failing test** using a mock delegate.

```swift
func test_tapPayWithCompleteCardRequestsConfirmNewCard() {
    let vc = makeVC(savedCards: [])
    vc.loadViewIfNeeded()
    vc.fillCardForTest()
    let delegate = MockContentDelegate(); vc.delegate = delegate
    vc.simulateTapPay()
    guard case .confirmNewCard = delegate.lastRequestedAction else { return XCTFail() }
    XCTAssertTrue(delegate.didChangeProcessingTrue)
}
func test_applySuccessFinishesWithOutcome() {
    let vc = makeVC(savedCards: []); vc.loadViewIfNeeded()
    let delegate = MockContentDelegate(); vc.delegate = delegate
    vc.simulateTapPay(); vc.applyOutcome(.succeeded(txnId: "t"))
    // after success animation, delegate.didFinishWith is called
    XCTAssertEqual(delegate.finishedOutcome, .succeeded(txnId: "t"))
}
func test_applyFailedStaysEditableAndReportsFailedState() {
    let vc = makeVC(savedCards: []); vc.loadViewIfNeeded()
    let delegate = MockContentDelegate(); vc.delegate = delegate
    vc.simulateTapPay(); vc.applyOutcome(.failed(txnId: nil, error: CheckoutErrorsFixture.paymentFailed()))
    XCTAssertEqual(delegate.lastState, .failed)
}
```

- [ ] **Step 2: Run test to verify it fails** — Run: `swift test --filter CheckoutContentViewControllerTests` Expected: FAIL.

- [ ] **Step 3: Implement** the delegate protocol and VC. On a confirm action: set state `.processing`, call `delegate.didChangeProcessing(true)`, emit `delegate.content(didRequest:)`. `applyOutcome` runs the state machine; `.autoClose` → animate `ConfirmButton.succeeded` then `delegate.didFinishWith`; `.showError` → `InlineNoticeView(.error)`; `.showInfoNotice` → `InlineNoticeView(.info)` + back to editing + `didChangeProcessing(false)`. Emit `didChangeState` on every transition. Enforce `minimumFlightTime` before applying terminal UI.

- [ ] **Step 4: Run test to verify it passes** — Run: `swift test --filter CheckoutContentViewControllerTests` Expected: PASS

- [ ] **Step 5: Commit**

```bash
git add Sources/SunbayCheckout/UI/Content/CheckoutContentDelegate.swift Sources/SunbayCheckout/UI/Content/CheckoutContentViewController.swift Tests/SunbayCheckoutTests/UI/CheckoutContentViewControllerTests.swift
git commit -m "feat(ui): checkout content view controller and delegate"
```

---

### Task 9: Bottom-sheet container + PaymentSheet rewiring

**Files:**
- Create: `Sources/SunbayCheckout/UI/Container/PaymentSheetContainerViewController.swift`
- Modify: `Sources/SunbayCheckout/UI/PaymentSheet/PaymentSheet.swift`
- Delete: `Sources/SunbayCheckout/UI/PaymentSheet/PaymentSheetViewController.swift`
- Modify: `Sources/SunbayCheckout/Public/SunbayCheckout.swift` (add optional `addressMetadataService` injection + `makeController` unchanged; thread `onStateChange`)
- Test: `Tests/SunbayCheckoutTests/UI/PaymentSheetRunCheckoutTests.swift` (extend existing runCheckout tests for the retry loop)

**Interfaces:**
- Consumes: `CheckoutContentViewController` + `CheckoutContentDelegate` (Task 8); `ResolvedAppearance` (Task 2); existing `CheckoutController`, `runCheckout` seam, `LocalizationResolver`.
- Produces:
  - `final class PaymentSheetContainerViewController: UIViewController, CheckoutContentDelegate` — hosts the content VC via `addChild`, configures `UISheetPresentationController` (grabber, corner radius, detents: iOS 16+ adaptive `.custom` + `invalidateDetents()`, iOS 15 `.medium/.large`), sets `isModalInPresentation` from `didChangeProcessing`, maps cancel/pull-down (editing) to `.canceled`, `didFinishWith` → dismiss+return.
  - `PaymentSheet`: `present(from:)` unchanged signature; internals build `ResolvedAppearance` + content VC + container; `runCheckout` extended to a retry loop (failed/notice → await next action); new `public var onStateChange: ((CheckoutPresentationState) -> Void)?`.

- [ ] **Step 1: Write the failing test** extending runCheckout tests (no real UIKit presentation; drive the seam directly).

```swift
func test_retryAfterFailedConfirmsAgain() async {
    // inject a controller whose first confirm fails, second succeeds;
    // a seam that returns confirmNewCard twice then observes outcomes
    let outcome = await sheet.runCheckout { ctx in /* return actions across rounds */ }
    XCTAssertEqual(outcome, .succeeded(txnId: "t2"))
}
func test_singleActiveGuardStillHoldsAcrossRounds() async {
    // assert each confirm maps to exactly one attempt; no blind resubmit
}
```

- [ ] **Step 2: Run test to verify it fails** — Run: `swift test --filter PaymentSheetRunCheckoutTests` Expected: FAIL.

- [ ] **Step 3: Implement** the container VC, the `PaymentSheet` rewiring, delete the old VC, and add the optional `addressMetadataService` parameter on `SunbayCheckout` (defaulting to a wrapped mock/default so existing call sites compile). Keep `runCheckout`'s start→COF→seam→confirm core; wrap the seam/confirm in a loop that continues on `.failed`/`.pending`/`.unknown` until success/cancel/terminal-accepted.

- [ ] **Step 4: Run test to verify it passes** — Run: `swift test --filter PaymentSheetRunCheckoutTests` Expected: PASS

- [ ] **Step 5: Run full suite** — Run: `swift test` Expected: PASS.

- [ ] **Step 6: Commit**

```bash
git add Sources/SunbayCheckout/UI/Container Sources/SunbayCheckout/UI/PaymentSheet Sources/SunbayCheckout/Public/SunbayCheckout.swift Tests/SunbayCheckoutTests/UI/PaymentSheetRunCheckoutTests.swift
git rm Sources/SunbayCheckout/UI/PaymentSheet/PaymentSheetViewController.swift
git commit -m "feat(ui): bottom-sheet container and PaymentSheet rewiring with retry loop"
```

---

### Task 10: ApplePayButton renders PKPaymentButton

**Files:**
- Modify: `Sources/SunbayCheckout/UI/Wallet/ApplePayButton.swift`
- Test: `Tests/SunbayCheckoutTests/UI/ApplePayButtonStyleTests.swift`

**Interfaces:**
- Consumes: existing `ApplePayButton` public API; PassKit.
- Produces: internal `func makePKPaymentButton(for style: ApplePayButtonStyle, trait: UIUserInterfaceStyle) -> PKPaymentButtonStyle` mapping (`.black`→`.black`, `.white`→`.white`/`.whiteOutline`, `.automatic`→by trait, downgrade on old OS), with `PKPaymentButton` rendered as a pinned subview; public API unchanged.

- [ ] **Step 1: Write the failing test**

```swift
func test_automaticMapsByTrait() {
    XCTAssertEqual(ApplePayButton.pkStyle(for: .automatic, trait: .dark), .white)
    XCTAssertEqual(ApplePayButton.pkStyle(for: .automatic, trait: .light), .black)
}
func test_fixedStylesMapDirectly() {
    XCTAssertEqual(ApplePayButton.pkStyle(for: .black, trait: .light), .black)
    XCTAssertEqual(ApplePayButton.pkStyle(for: .white, trait: .light), .white)
}
```

- [ ] **Step 2: Run test to verify it fails** — Run: `swift test --filter ApplePayButtonStyleTests` Expected: FAIL.

- [ ] **Step 3: Implement** the static `pkStyle(for:trait:)` mapping and swap the self-drawn visuals for a `PKPaymentButton` subview, keeping `onResult`/`onAvailabilityChange`/`isAvailable`/tap→authorize→confirmWallet intact.

- [ ] **Step 4: Run test to verify it passes** — Run: `swift test --filter ApplePayButtonStyleTests` Expected: PASS

- [ ] **Step 5: Commit**

```bash
git add Sources/SunbayCheckout/UI/Wallet/ApplePayButton.swift Tests/SunbayCheckoutTests/UI/ApplePayButtonStyleTests.swift
git commit -m "feat(ui): render ApplePayButton via official PKPaymentButton"
```

---

### Task 11: Localization keys (en + zh-Hans)

**Files:**
- Modify: `Sources/SunbayCheckout/Resources/Localizations/en.lproj/Localizable.strings`
- Modify: `Sources/SunbayCheckout/Resources/Localizations/zh-Hans.lproj/Localizable.strings`
- Test: `Tests/SunbayCheckoutTests/UI/LocalizationKeyCoverageTests.swift`

**Interfaces:**
- Consumes: `LocalizationResolver` (existing).
- Produces: the new keys from spec §7.2 present in both tables (sheet structure, card form, field errors, CTA/state, address simple+structural, COF, common.retry).

- [ ] **Step 1: Write the failing test** that loads both `.lproj` bundles and asserts every key in a canonical list resolves (not equal to the key itself) in both.

```swift
func test_allNewKeysPresentInEnAndZhHans() {
    for key in SunbayUIStringKeys.all {
        XCTAssertNotEqual(resolve(key, "en"), key, "missing en: \(key)")
        XCTAssertNotEqual(resolve(key, "zh-Hans"), key, "missing zh-Hans: \(key)")
    }
}
```

- [ ] **Step 2: Run test to verify it fails** — Run: `swift test --filter LocalizationKeyCoverageTests` Expected: FAIL.

- [ ] **Step 3: Implement** a `SunbayUIStringKeys.all` constant listing the canonical keys and add every key to both `.strings` files (English values; zh-Hans translations).

- [ ] **Step 4: Run test to verify it passes** — Run: `swift test --filter LocalizationKeyCoverageTests` Expected: PASS

- [ ] **Step 5: Commit**

```bash
git add Sources/SunbayCheckout/Resources/Localizations Tests/SunbayCheckoutTests/UI/LocalizationKeyCoverageTests.swift
git commit -m "feat(i18n): add checkout UI strings in en and zh-Hans"
```

---

### Task 12: Demo app + test-support doubles wiring

**Files:**
- Create: `Sources/SunbayCheckoutTestSupport/ScriptableAddressMetadataService.swift`
- Modify: `Example/SunbayCheckoutDemo/Sources/DemoRootView.swift` and `DemoSettings.swift` (exercise appearance presets, dark/light, simple/full address, COF, all 7 screen states)
- Test: none new (demo is the manual gate); run `swift build`.

**Interfaces:**
- Consumes: public API only (`SunbayCheckout(configuration:paymentService:cofService:addressMetadataService:)`, `PaymentSheet`, `Appearance`, `ApplePayButton`); `AddressMetadataService` (Task 3).
- Produces: `public struct ScriptableAddressMetadataService: AddressMetadataService` with stub countries/config (public-API-only, no internal types), and demo controls for appearance/scheme/address-mode/scenario.

- [ ] **Step 1: Implement** `ScriptableAddressMetadataService` and demo wiring (appearance presets mirroring the prototype's Customize lab: default orange, sharp blue express-bottom, round green dark; a scheme toggle; billing/shipping mode toggles).

- [ ] **Step 2: Build** — Run: `swift build` Expected: success. (Demo is a Tuist app; also verify it compiles against the public surface — `swift build` for the package, Tuist generate for the app if available.)

- [ ] **Step 3: Run full suite** — Run: `swift test` Expected: PASS.

- [ ] **Step 4: Commit**

```bash
git add Sources/SunbayCheckoutTestSupport/ScriptableAddressMetadataService.swift Example/SunbayCheckoutDemo/Sources/DemoRootView.swift Example/SunbayCheckoutDemo/Sources/DemoSettings.swift
git commit -m "feat(demo): scriptable address service and appearance/scheme/address demo controls"
```

---

### Task 13: Optional snapshot tests (key screens)

**Files:**
- Create: `Tests/SunbayCheckoutTests/UI/Snapshots/CheckoutContentSnapshotTests.swift` (gated so it is NOT part of the `swift test` host gate)

**Interfaces:**
- Consumes: `CheckoutContentViewController`, `ResolvedAppearance`.
- Produces: optional snapshot coverage for home / saved / new-card / field-error / processing / success in light + dark.

- [ ] **Step 1: Implement** snapshots using the project's chosen snapshot mechanism (or a lightweight render-to-image compare), gated behind an iOS-simulator-only / opt-in flag so host `swift test` is unaffected.

- [ ] **Step 2: Verify** host `swift test` still passes without running snapshots — Run: `swift test` Expected: PASS.

- [ ] **Step 3: Commit**

```bash
git add Tests/SunbayCheckoutTests/UI/Snapshots
git commit -m "test(ui): optional snapshot coverage for key checkout screens"
```

---

### Task 14: Documentation sync

**Files:**
- Modify: `docs/product-spec.md` (Appearance §2.1 shape; address collection modes; in-sheet states), `README.md` (Appearance usage + onStateChange), `AGENTS.md` (tree additions: Theme/Content/Container, AddressMetadata)
- Test: none; prose only.

- [ ] **Step 1: Update** the docs to reflect the shipped `Appearance`, address modes, in-sheet state machine, and new directories. Keep English-only.

- [ ] **Step 2: Commit**

```bash
git add docs/product-spec.md README.md AGENTS.md
git commit -m "docs: sync spec/readme/agents with the redesigned UI layer"
```
