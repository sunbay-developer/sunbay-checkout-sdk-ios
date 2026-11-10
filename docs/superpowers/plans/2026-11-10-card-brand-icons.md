# Card Brand Icons Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace the card form's fixed system card icon with HPP-style session-driven brand icons (2 fixed + rotating slot when empty, single matched icon when typing) and add the HPP CVV icon.

**Architecture:** A pure Core model turns session `MethodEntry` values into `CardBrandItem`s and matches a scheme. A UIKit `CardBrandIconsView` renders them (carousel / single / none) using an in-memory `CardBrandLogoLoader`. `CardFormView` owns the view and feeds it the PAN-empty state and the effective scheme.

**Tech Stack:** Swift, UIKit, URLSession, XCTest, SwiftPM resources.

**Spec:** `docs/superpowers/specs/2026-11-10-card-brand-icons-design.md`

## Global Constraints

- English only in code, comments, identifiers, tests, docs (`AGENTS.md` rule 2).
- Core types import no UIKit; UIKit code is wrapped in `#if canImport(UIKit)` (compiles out under macOS `swift test`).
- No card values / BIN in logs; logo requests carry only the logo URL; image cache is in-memory only (no disk, UserDefaults, Keychain).
- No public API change. Minimum iOS 15.
- Do not commit; do not `git add .`. Work on a `feature/card-brand-icons` branch, not `main`.
- Carousel: 2 fixed icons, rotating slot every 2 s, 0.3 s cross-fade; icon 32x20 pt, 4 pt spacing. CVV icon 34x20 pt, gap 8 pt to the field.

## Review Focus

- Zero card entries / entries without `logoURL`: show the system `creditcard` fallback, no crash.
- All logo loads fail: same fallback; a failed single logo is skipped, not shown blank.
- PAN cleared back to empty: carousel returns; recognized scheme dropped: nothing shown (HPP behavior).
- Recognized scheme not in the session's brands (e.g. `mir`): nothing shown.
- Duplicate `method` entries or non-HTTPS / malformed URLs: deduped / ignored.
- Reduce Motion on: no cross-fade. View off-screen: timer stopped (no leak, no retain cycle).

---

### Task 1: `CardBrandItem` model (Core)

**Files:**
- Create: `Sources/SunbayCheckout/Core/CardBrand/CardBrandItem.swift`
- Test: `Tests/SunbayCheckoutTests/Core/CardBrandItemTests.swift`

**Interfaces:**
- Produces:
  - `struct CardBrandItem: Equatable, Sendable { let scheme: String; let name: String; let logoURL: URL }` (`scheme` is lowercased/trimmed `method`).
  - `static func CardBrandItem.items(from entries: [MethodEntry]) -> [CardBrandItem]` — keeps `type == "CARD"` entries with an `https` `logoURL` that parses, backend order, first occurrence per scheme.
  - `static func CardBrandItem.item(matching scheme: String?, in items: [CardBrandItem]) -> CardBrandItem?` — case-insensitive, trimmed; nil/empty → nil.

- [ ] **Step 1: Write failing tests** `test_items_keepsOnlyCardEntriesWithHTTPSLogo`, `test_items_dedupesBySchemeKeepingFirst`, `test_items_preservesBackendOrder`, `test_item_matchingIsCaseInsensitive` (`"VISA"` entry matches `"visa"`), `test_item_matchingDinersclub` (`"DINERSCLUB"` matches `"dinersclub"`), `test_item_nilOrUnknownSchemeReturnsNil`. Entries built as `MethodEntry(method:type:name:logoURL:)`.
- [ ] **Step 2: Run** `swift test --filter CardBrandItemTests`. Expected: FAIL (type not defined).
- [ ] **Step 3: Implement** `CardBrandItem` as specified in Interfaces.
- [ ] **Step 4: Run** `swift test --filter CardBrandItemTests`. Expected: PASS.

### Task 2: `CardBrandLogoLoader` (UI, in-memory)

**Files:**
- Create: `Sources/SunbayCheckout/UI/Content/Components/CardBrandLogoLoader.swift`
- Test: `Tests/SunbayCheckoutTests/UI/CardBrandLogoLoaderTests.swift` (both files inside `#if canImport(UIKit)`)

**Interfaces:**
- Produces: `@MainActor final class CardBrandLogoLoader` with
  - `init(fetch: @escaping @Sendable (URL) async throws -> Data = CardBrandLogoLoader.defaultFetch)` (default uses an ephemeral `URLSession`, 10 s timeout, no cookies/credentials);
  - `func image(for url: URL, completion: @escaping (UIImage?) -> Void)` — returns cached image synchronously-in-callback, coalesces concurrent requests for the same URL, calls `completion(nil)` on failure or undecodable data; completion always on the main actor;
  - cache is an `NSCache<NSURL, UIImage>`.

- [ ] **Step 1: Write failing tests** with a stub `fetch`: `test_loadsAndCachesImage` (fetch count == 1 for two requests of the same URL), `test_failureCompletesWithNil`, `test_undecodableDataCompletesWithNil`, `test_concurrentRequestsCoalesce` (fetch count == 1, both completions fire). Use a PNG generated with `UIGraphicsImageRenderer(...).pngData`.
- [ ] **Step 2: Run** `xcodebuild test -scheme SunbayCheckout -destination 'platform=iOS Simulator,name=iPhone 15' -only-testing:SunbayCheckoutTests/CardBrandLogoLoaderTests`. Expected: FAIL.
- [ ] **Step 3: Implement** as specified.
- [ ] **Step 4: Re-run** the same command. Expected: PASS.

### Task 3: `CardBrandIconsView` (UI)

**Files:**
- Create: `Sources/SunbayCheckout/UI/Content/Components/CardBrandIconsView.swift`
- Test: `Tests/SunbayCheckoutTests/UI/CardBrandIconsViewTests.swift`

**Interfaces:**
- Consumes: `CardBrandItem`, `CardBrandLogoLoader`, `ResolvedAppearance` (for the fallback tint `textSecondary`).
- Produces: `final class CardBrandIconsView: UIView` with
  - `init(appearance: ResolvedAppearance, loader: CardBrandLogoLoader = .init(), interval: TimeInterval = 2, visibleCount: Int = 2)`;
  - `func configure(items: [CardBrandItem])`;
  - `func update(isEmpty: Bool, scheme: String?)` — empty → carousel; non-empty → matched item only, or nothing;
  - `override var intrinsicContentSize` (width follows what is shown, height 20);
  - DEBUG test readouts: `visibleSchemesForTest: [String]`, `showsFallbackForTest: Bool`, `isRotatingForTest: Bool`, `func advanceForTest()` (one rotation step, no timer wait).
  - Behavior: items ≤ `visibleCount` → all shown, no rotation; otherwise fixed `items.prefix(2)` + rotating slot cycling `items.dropFirst(2)`; timer runs only when empty, ≥3 items, and `window != nil` (start in `didMoveToWindow`, invalidate on removal and `deinit`, weak-self target); cross-fade 0.3 s skipped when `UIAccessibility.isReduceMotionEnabled`; items whose logo failed are dropped from display; if no item has a loaded logo (or `items` empty) show the system `creditcard` image tinted `appearance.textSecondary` only in the empty state.

- [ ] **Step 1: Write failing tests** (loader stub that resolves images by URL): `test_emptyShowsFirstTwoPlusRotatingSlot`, `test_advanceCyclesThroughRemainingBrands`, `test_twoOrFewerBrandsShowAllAndDoNotRotate`, `test_typingShowsOnlyMatchedBrand` (`update(isEmpty:false, scheme:"visa")`), `test_typingUnrecognizedShowsNothing`, `test_unknownSchemeNotInSessionShowsNothing`, `test_noItemsShowsFallbackWhenEmpty`, `test_allLogosFailShowsFallbackWhenEmpty`, `test_failedLogoIsSkipped`, `test_clearingBackToEmptyRestoresCarousel`.
- [ ] **Step 2: Run** `xcodebuild test ... -only-testing:SunbayCheckoutTests/CardBrandIconsViewTests`. Expected: FAIL.
- [ ] **Step 3: Implement** as specified.
- [ ] **Step 4: Re-run.** Expected: PASS.

### Task 4: Wire into `CardFormView`, CVV icon, resources

**Files:**
- Modify: `Sources/SunbayCheckout/UI/Content/Components/CardFormView.swift` (`brandIconView` at lines 42, 253-257, 296-301; `textField(_:shouldChangeCharactersIn:...)` PAN branch; `setBackendScheme`; `applyScannedCard`; `cvvField` trailing constraint at line 324)
- Modify: `Sources/SunbayCheckout/UI/Content/CheckoutContentViewController.swift:97` (pass brand items)
- Modify: `Package.swift:35` (add `.process("Resources/Images")`)
- Create: `Sources/SunbayCheckout/Resources/Images/cvv-icon@2x.png`, `cvv-icon@3x.png` (export from `/Users/sm4267/workspace/web/checkout/public/imgs/cvv-icon.svg`, 34x20 pt, e.g. `rsvg-convert -w 68 -h 40` and `-w 102 -h 60`; keep the artwork aspect ratio; if `rsvg-convert` is missing, render via `qlmanage`/Safari export or `sips` from a PDF)
- Test: `Tests/SunbayCheckoutTests/UI/CardFormViewTests.swift`

**Interfaces:**
- Consumes: `CardBrandItem.items(from:)`, `CardBrandItem.item(matching:in:)`, `CardBrandIconsView` (Task 3).
- Produces: `CardFormView.init(appearance:localize:ruleSet:brandItems: [CardBrandItem] = [])` (new defaulted last parameter); private `refreshBrandIcons()`; DEBUG readouts `brandSchemesForTest: [String]`, `hasCVVIconForTest: Bool`.

- [ ] **Step 1: Write failing tests** in `CardFormViewTests`: `test_emptyPANShowsBrandCarouselItems`, `test_typingVisaPrefixShowsOnlyVisa` (via `setFieldsForTest` is not enough — drive through the delegate `textField(_:shouldChangeCharactersIn:replacementString:)` on the PAN field, exposed by a DEBUG `typePANForTest(_:)` helper that calls it), `test_backendSchemeOverridesLocalGuess`, `test_clearingPANRestoresCarousel`, `test_cvvIconPresent`. Existing `cardInput` tests must stay green.
- [ ] **Step 2: Run** `xcodebuild test ... -only-testing:SunbayCheckoutTests/CardFormViewTests`. Expected: FAIL.
- [ ] **Step 3: Implement.** Replace `brandIconView` with `CardBrandIconsView` (same trailing `-12`, centerY on `panField`; `panField.trailing` pinned to its leading `-8`; width from intrinsic size, so the field text area shrinks only as much as the icons need). Call `refreshBrandIcons()` (→ `update(isEmpty: digits.isEmpty, scheme: backendScheme ?? localScheme)`) after every PAN edit, in `setBackendScheme`, and in `applyScannedCard`. Add a non-interactive 34x20 `UIImageView` for the CVV icon (`UIImage(named: "cvv-icon", in: .module, compatibleWith: nil)`), trailing `-12`, centerY on `cvvField`; `cvvField.trailing` pinned to its leading `-8`. In `CheckoutContentViewController`, build `CardBrandItem.items(from: entries)` from the same filtered `entries` that decide `cardAvailable` (keep it in a stored property used at line 97 — make `cardForm` creation read it).
- [ ] **Step 4: Re-run** the CardFormView tests. Expected: PASS.

### Task 5: Full verification and docs

**Files:**
- Modify: `docs/real-api-integration-checklist.md`, `docs/product-spec.md` (one line each: card-form brand icons use session `paymentMethods[].logoUrl`; real-data check on dev pending)

- [ ] **Step 1:** `swift test`. Expected: all pass (UIKit files compile out on the host).
- [ ] **Step 2:** `xcodebuild test -scheme SunbayCheckout -destination 'platform=iOS Simulator,name=iPhone 15'`. Expected: all pass; if snapshot tests fail only from the icon area, regenerate their references and note it.
- [ ] **Step 3:** From `Example/SunbayCheckoutDemo` run `tuist generate`, then `xcodebuild -workspace Example/SunbayCheckoutDemo/SunbayCheckoutDemo.xcworkspace -scheme SunbayCheckoutDemo -destination 'generic/platform=iOS Simulator' build`. Expected: BUILD SUCCEEDED.
- [ ] **Step 4:** Run the demo on the simulator against dev and confirm visually: empty field shows 2 fixed + rotating icons; typing `4` shows Visa; `5` Mastercard; clearing restores the carousel; CVV icon visible without overlapping text.
- [ ] **Step 5:** Add the two doc lines; report results to the user. Commit only if the user asks.

## Self-Review

- Spec coverage: carousel (T3), matched icon (T3/T4), session-sourced icons (T1/T4), recognition reuse (T4), CVV icon (T4), in-memory cache (T2), Reduce Motion / timer rules (T3), docs (T5).
- Types: `CardBrandItem`, `items(from:)`, `item(matching:in:)`, `update(isEmpty:scheme:)`, `configure(items:)` used consistently across tasks.
