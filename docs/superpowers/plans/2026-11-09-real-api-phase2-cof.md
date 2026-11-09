# Real API Integration, Phase 2 (saved cards / COF) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Saved cards work against the real backend: the SDK lists the customer's cards via `card/list`, pays with one (`paymentMethod: "TOKEN"`), and stores a new card when the user ticks "save", all gated by one effective COF decision that the session, the host options and the customer secret control together.

**Architecture:** A new internal `HTTPCofService` on the existing `SunbayAPIClient` replaces `UnconfiguredCofService` in the default wiring. A new public value type `CardOnFileOptions` on `CheckoutConfiguration` carries host switches. `CheckoutController` computes `isCardOnFileEnabled` once after `start` and every COF path (listing, `storeCard`, the save checkbox) reads only that.

**Tech Stack:** Swift 5.9, URLSession, XCTest (host `swift test` + iOS simulator `xcodebuild test` for UIKit tests), Node dev server from Phase 1.

**Spec:** `docs/superpowers/specs/2026-11-09-real-api-integration-design.md` (§5.3 rows "Saved-card pay", "Save a new card", "COF available", "List cards", "Card item"; §5.5 phase 2; §5.8). Backend contract: `docs/api/checkout-api.json` (`CardListReq`, `CardListResp`, `CardItem`, `SubmitSessionPaymentReq`).

## Global Constraints

- Swift only; all code, comments, strings, test names, commit messages and docs in English (`AGENTS.md` §2). Core imports no UIKit/PassKit. iOS 15.
- `customerAccessSecret`, `checkoutClientSecret`, card data and request/response bodies never reach logs, errors, descriptions or public callbacks.
- Effective COF = `session.cofEnabled` (backend `supportStoreCard`, absent means `true`) `&&` `configuration.cardOnFile.isEnabled` `&&` a non-nil `customerAccessSecret`. The host can never turn on COF that the session turned off.
- When effective COF is false: no `card/list` request, no saved-card UI, no save checkbox, `storeCard` never sent.
- `storeCard: true` is sent only when the user's checkbox is on at submit time; `saveByDefault` only sets the initial checkbox state. `CardOnFileOptions()` defaults: `isEnabled = true`, `saveByDefault = false`.
- Listing never blocks payment: any `card/list` failure (network, `S06 Unauthorized`, decoding) degrades to "no saved cards"; never surfaced as a payment error.
- Live facts (dev, 2026-11-09): `POST /api/checkout/web/card/list` body `{sessionId, customerAccessSecret}` returns envelope `data: {cards: [CardItem]}`; bad secret returns HTTP 200 + `code "S06"`, missing secret `C16`. `CardItem`: `savedCardId` (`sc_…`), `maskedCardNumber` (for example `**** **** **** 4242`), `cardBrand` (lower-case), `expiryMonth` `"MM"`, `expiryYear` `"YY"`, `cardholderName`.
- No polling (unchanged). Branch `feature/real-api-phase2-cof`; commits with exact files only, never `git add .`, never `git add -f`, never push.
- Out of scope: address (phase 3), card rules/BIN (phase 4), removing a saved card, `cardholderName` display.

## Review Focus

1. A `CardItem` with a malformed `maskedCardNumber` (no 4 trailing digits), a bad `expiryMonth` (`"13"`, `"ab"`) or `expiryYear` (`"5"`): that one card is dropped, the rest still show; no crash, no whole-list failure.
2. `customerAccessSecret` present but the session has `supportStoreCard: false`: zero `card/list` requests and no checkbox, even if `CardOnFileOptions.isEnabled` is true.
3. `saveByDefault: true` and the user unticks the box: `storeCard` must be absent from the submit body.
4. A saved card is selected, then the user switches to the new-card page and pays: the submit is a `CARD` submit (no `savedCardId`, no `TOKEN`), and `storeCard` follows the checkbox.
5. `card/list` returns an envelope error or 5xx: the sheet still opens with new card + wallet only, and the payment flow is unaffected.

---

### Task 1: CardOnFileOptions and the effective COF decision (Core)

**Files:**
- Create: `Sources/SunbayCheckout/Public/CardOnFileOptions.swift`
- Modify: `Sources/SunbayCheckout/Public/CheckoutConfiguration.swift` (both `#if canImport(UIKit)` and `#else` inits gain `cardOnFile: CardOnFileOptions = CardOnFileOptions()` as the last parameter), `Sources/SunbayCheckout/Public/SunbayCheckout.swift` (`makeController` passes `configuration.cardOnFile`), `Sources/SunbayCheckout/Core/CheckoutController.swift`, `Tests/SunbayCheckoutE2ETests/E2ESupport.swift` and any other `CheckoutController(` call site that stops compiling
- Test: `Tests/SunbayCheckoutTests/Core/CheckoutControllerTests.swift`, `Tests/SunbayCheckoutTests/Public/CardOnFileOptionsTests.swift`

**Interfaces:**
- Produces:
  - `public struct CardOnFileOptions: Sendable, Equatable { public var isEnabled: Bool; public var saveByDefault: Bool; public init(isEnabled: Bool = true, saveByDefault: Bool = false) }`
  - `CheckoutConfiguration.cardOnFile: CardOnFileOptions` (public let).
  - `CheckoutController.init(paymentService:cofService:credentials:actionHandler:cardOnFile: CardOnFileOptions = CardOnFileOptions())`.
  - `CheckoutController.isCardOnFileEnabled: Bool` (actor-isolated computed property; `false` before `start`): `session?.cofEnabled == true && cardOnFile.isEnabled && credentials.current() != nil` evaluated at `start` time and stored, so a later credential clear on `dismiss` sets it back to `false`.
  - `CheckoutController.cardOnFileSaveByDefault: Bool` returns `isCardOnFileEnabled && cardOnFile.saveByDefault`.
  - `listSavedCards()` returns `[]` without calling the service unless `isCardOnFileEnabled`.
  - `confirmNewCard(_:save:)` sends `storeCard: true` only when `save && isCardOnFileEnabled`.

- [ ] **Step 1: Write failing tests** in `CheckoutControllerTests`: (a) session `cofEnabled: true`, options default, secret `"cas_1"` → `isCardOnFileEnabled == true`, `listSavedCards()` calls the cof service once; (b) same but session `cofEnabled: false` → `false`, cof service call count `0`, `confirmNewCard(save: true)` submits `storeCard == nil`; (c) options `isEnabled: false` with session `true` and secret → `false`, call count `0`, `storeCard == nil`; (d) no secret → `false`, call count `0`; (e) `saveByDefault: true` with effective COF → `cardOnFileSaveByDefault == true`, with session `cofEnabled: false` → `false`; (f) before `start` and after `dismiss()` → `isCardOnFileEnabled == false`. In `CardOnFileOptionsTests`: `CardOnFileOptions()` has `isEnabled == true`, `saveByDefault == false`; `CheckoutConfiguration()` has `cardOnFile == CardOnFileOptions()`.
- [ ] **Step 2:** Run `swift test --filter 'CheckoutControllerTests|CardOnFileOptionsTests'`. Expected: FAIL (types and members missing).
- [ ] **Step 3: Implement** the interface block. Document `CardOnFileOptions` in English, including that the session switch wins and that `saveByDefault` only pre-ticks the checkbox.
- [ ] **Step 4:** Run `swift test` (full). Expected: 0 failures.
- [ ] **Step 5: Commit**: `feat(cof): add CardOnFileOptions and a single effective COF decision in the controller`.

---

### Task 2: Sheet and content wiring for the COF decision (UI)

**Files:**
- Modify: `Sources/SunbayCheckout/UI/PaymentSheet/PaymentSheet.swift` (around the `customerAccessSecret != nil && session.cofEnabled` decision and `CheckoutContext`), `Sources/SunbayCheckout/UI/Content/CheckoutContentViewController.swift` (init, `if session.cofEnabled` save-row block, `makeSaveCardRow`), any other construction site of `CheckoutContentViewController` (`grep -rn "CheckoutContentViewController(" Sources Tests`)
- Test: `Tests/SunbayCheckoutTests/UI/CheckoutContentViewControllerTests.swift`, `Tests/SunbayCheckoutTests/UI/PaymentSheetRunCheckoutTests.swift`

**Interfaces:**
- Consumes: `CheckoutController.isCardOnFileEnabled`, `CheckoutController.cardOnFileSaveByDefault` (Task 1).
- Produces:
  - `PaymentSheet.CheckoutContext` gains `cardOnFileEnabled: Bool` and `saveCardByDefault: Bool`; the sheet lists cards iff `await controller.isCardOnFileEnabled`.
  - `CheckoutContentViewController.init(...)` gains `cardOnFileEnabled: Bool = false, saveCardByDefault: Bool = false`; the save row is shown iff `cardOnFileEnabled` (no longer reads `session.cofEnabled`), and the checkbox's initial `isOn` is `saveCardByDefault`.
  - A DEBUG test seam on the content VC if none exists: `var isSaveCardRowVisibleForTest: Bool` and `var isSaveCardOnForTest: Bool`, plus `func setSaveCardForTest(_ on: Bool)`.

- [ ] **Step 1: Write failing tests** (UIKit, simulator): content VC with `cardOnFileEnabled: false` and a session `cofEnabled: true` → save row hidden; `cardOnFileEnabled: true, saveCardByDefault: true` → row visible and on; then `setSaveCardForTest(false)` and confirm the new card → delegate receives `.confirmNewCard(_, save: false)`; `cardOnFileEnabled: true, saveCardByDefault: false` → row visible and off. In `PaymentSheetRunCheckoutTests`: with options `isEnabled: false` the scripted cof service gets 0 list calls; with defaults and a secret it gets 1. Update existing tests that relied on `session.cofEnabled` showing the save row (pass `cardOnFileEnabled: true`).
- [ ] **Step 2:** Run `xcodebuild test -scheme SunbayCheckout-Package -destination 'platform=iOS Simulator,name=iPhone 17 Pro' -only-testing:SunbayCheckoutTests/CheckoutContentViewControllerTests -only-testing:SunbayCheckoutTests/PaymentSheetRunCheckoutTests`. Expected: FAIL (compile errors on new parameters). If that scheme or simulator name does not exist, use `xcodebuild -list` and `xcrun simctl list devices available` to pick the equivalent and record the command used in the report.
- [ ] **Step 3: Implement** the interface block. Keep the existing "zero verification" saved-card flow unchanged.
- [ ] **Step 4:** Run the same `xcodebuild test` filter (PASS), then the full simulator suite once (`xcodebuild test -scheme SunbayCheckout-Package -destination ...` without `-only-testing`) and `swift test`. Expected: 0 failures in both.
- [ ] **Step 5: Commit**: `feat(cof): drive the saved-card list and save checkbox from the effective COF decision`.

---

### Task 3: HTTPCofService and default wiring

**Files:**
- Create: `Sources/SunbayCheckout/Core/Network/HTTPCofService.swift`
- Modify: `Sources/SunbayCheckout/Core/Network/SunbayEndpoints.swift` (new route), `Sources/SunbayCheckout/Public/SunbayCheckout.swift` (default `serviceFactory` builds `HTTPCofService` on the same `SunbayAPIClient`), `Sources/SunbayCheckout/Core/UnconfiguredServices.swift` (delete the file if nothing references `UnconfiguredCofService` any more), `Sources/SunbayCheckout/Core/CofService.swift` (doc comment: real adapter now exists; listing failures degrade)
- Test: `Tests/SunbayCheckoutTests/Core/HTTPCofServiceTests.swift`, `Tests/SunbayCheckoutTests/Core/SunbayEndpointsTests.swift`, `Tests/SunbayCheckoutTests/Public/SunbayCheckoutDefaultWiringTests.swift`

**Interfaces:**
- Consumes: `SunbayAPIClient.post(_:body:timeout:)`, `StubURLProtocol` test helper.
- Produces:
  - `SunbayEndpoints.Route.cardList` → `{origin}/api/checkout/web/card/list`.
  - `struct HTTPCofService: CofService { init(client: SunbayAPIClient) }`: `listPaymentMethods(customerAccessSecret:sessionId:)` posts `{"sessionId": ..., "customerAccessSecret": ...}` and maps `data.cards` to `[SavedCard]`.
  - Mapping (internal `static func map(_ item: CardItemWire) -> SavedCard?`): `id = savedCardId`; `brand = cardBrand.lowercased()`; `last4` = last 4 characters of `maskedCardNumber` after removing everything that is not an ASCII digit, required to be exactly 4 digits; `expMonth` = `Int(expiryMonth)` in `1...12`; `expYear` = `Int(expiryYear)`, `2000 + value` when the string has 2 digits, the value itself when it has 4 digits, otherwise invalid. Any invalid field drops that card (returns nil). A missing `cards` array or `data` decodes as an empty list. All wire fields are optional on decode so one bad item never fails the whole response.
  - Errors: whatever `SunbayAPIClient` throws is rethrown unchanged (the controller already degrades to `[]`).

- [ ] **Step 1: Write failing tests**: `SunbayEndpointsTests`: `.cardList` on `.dev` equals `https://checkout.sunbay-dev.com/api/checkout/web/card/list`. `HTTPCofServiceTests` (stubbed): request body is exactly `{"sessionId":"s1","customerAccessSecret":"cas_x"}` to the card-list path; `{"cards":[{"savedCardId":"sc_1","maskedCardNumber":"**** **** **** 4242","cardBrand":"VISA","expiryMonth":"07","expiryYear":"29","cardholderName":"A B"}]}` maps to `SavedCard(id:"sc_1", brand:"visa", last4:"4242", expMonth:7, expYear:2029)`; `expiryYear:"2031"` maps to 2031; items with `maskedCardNumber:"****"`, `expiryMonth:"13"`, `expiryMonth:"ab"`, `expiryYear:"5"`, or missing `savedCardId` are each dropped while a valid sibling survives; `data: {}` and `data: {"cards": []}` give `[]`; envelope `{"code":"S06","msg":"Unauthorized"}` throws a `CheckoutError` with code `S06`; the thrown error's message contains neither `cas_x` nor the request body. `SunbayCheckoutDefaultWiringTests`: the default checkout's controller lists cards through the stubbed session (request path ends `/card/list`) when the session has COF and a secret is held.
- [ ] **Step 2:** Run `swift test --filter 'HTTPCofServiceTests|SunbayEndpointsTests|SunbayCheckoutDefaultWiringTests'`. Expected: FAIL.
- [ ] **Step 3: Implement** the interface block.
- [ ] **Step 4:** Run the same filter (PASS), then full `swift test` and `swift build`. Expected: 0 failures.
- [ ] **Step 5: Commit**: `feat(cof): add HTTPCofService for card/list and use it by default`.

---

### Task 4: Real-API COF tests, Example switches, docs

**Files:**
- Modify: `Tests/SunbayCheckoutRealAPITests/RealAPIPaymentTests.swift` (or create `RealAPICofTests.swift` beside it), `Example/SunbayCheckoutDemo/Sources/DemoSettings.swift`, `Example/SunbayCheckoutDemo/Sources/DemoRootView.swift`, `docs/product-spec.md` (§2.1 configuration: `cardOnFile`; §7.5 list cards: real contract), `docs/real-api-integration-checklist.md`, `Example/README.md`
- Showcase: only if `Showcase/` builds a `CheckoutConfiguration` with an explicit argument list that now fails to compile; otherwise untouched.

**Interfaces:**
- Consumes: `HTTPCofService`, `CardOnFileOptions`, `DevSessionClient`, `CheckoutController` COF members.

- [ ] **Step 1: Real-API tests** (skip rules as in Phase 1: skip without `SUNBAY_DEV_SERVER_URL`, only `.dev`/`.test`): (a) `testCardListWithValidSecretReturnsArray`: new dev session, `HTTPCofService.listPaymentMethods` with its `customerAccessSecret` returns without throwing (empty allowed); (b) `testCardListWithWrongSecretIsUnauthorized`: a well-formed but wrong `cas_` value throws `CheckoutError` with code `S06` and a category other than `.network`; (c) `testStoreThenPayWithSavedCard` (skip unless `SUNBAY_TEST_CARD_*` are set): pay a new card with `save: true` → `.succeeded`; list on a **new** session for the same dev customer → contains a card whose `last4` equals the last 4 test-card digits; pay that card via `confirmSavedCard(paymentMethodId:)` → `.succeeded`. Run `scripts/run-dev-e2e.sh`; expected (a), (b) pass; (c) passes or is skipped; report which. If (b) returns a different code, report the observed code instead of changing the assertion to match silently.
- [ ] **Step 2: Example:** add two toggles to the Example settings, "Card on file enabled" (default on) and "Pre-tick save card" (default off), passed into `CheckoutConfiguration(cardOnFile:)` in both mock and real modes. In mock mode the existing scripted saved cards keep working. Run `tuist generate` in `Example/SunbayCheckoutDemo` and the simulator build `xcodebuild -workspace Example/SunbayCheckoutDemo/SunbayCheckoutDemo.xcworkspace -scheme SunbayCheckoutDemo -destination 'generic/platform=iOS Simulator' build`. Expected: BUILD SUCCEEDED.
- [ ] **Step 3: Docs (English):** `product-spec.md` §2.1 documents `cardOnFile` and the effective-COF rule; §7.5 replaces the old placeholder (`GET .../customer/payment-methods`, bearer header, `last4` fields) with the real `card/list` contract and the field mapping from Task 3. Checklist: tick "card list via real adapter"; record `S06` for a wrong secret and `C16` for a missing one; add open items "does a `storeCard: true` new-card submit also need `customerAccessSecret` to bind the card to the customer (verify with test (c))", "backend `supportStoreCard` rename still pending (session returns `storeCard`)"; add the two items carried over from Phase 1: `E03` is returned only for failed payments, so treating it as a definite failure is correct (confirmed by the user 2026-11-09), and "R with redirect returns `pending` without a result query or polling; revisit when QR payments are supported (user decision 2026-11-09)". `Example/README.md`: describe the two toggles.
- [ ] **Step 4:** Run `swift test` (full, 0 failures).
- [ ] **Step 5: Commit**: `test(cof): real-API card list tests, Example COF switches and docs`.

---

## Self-review notes

- Spec coverage: §5.8 semantics and public API (Tasks 1-2), §5.3 list/card-item/saved-card/save rows (Tasks 1, 3; saved-card submit fields already shipped in Phase 1), §5.5 phase 2 exit "list, pay with a saved card, and save a new card against dev" (Task 4 (c), gated on test-card env), Example/Showcase settings (Task 4).
- Types across tasks: `CardOnFileOptions(isEnabled:saveByDefault:)`, `CheckoutController.isCardOnFileEnabled` / `cardOnFileSaveByDefault`, `CheckoutContext.cardOnFileEnabled` / `saveCardByDefault`, content VC `cardOnFileEnabled:` / `saveCardByDefault:`, `HTTPCofService(client:)`, `Route.cardList`.
- Open verification: whether `storeCard` needs the customer secret on submit, and the end-to-end save-then-pay path, both depend on a sandbox test card.
