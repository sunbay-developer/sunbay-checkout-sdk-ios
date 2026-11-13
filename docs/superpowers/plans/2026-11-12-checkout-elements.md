# Checkout Elements (Block 2) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Ship embeddable payment components: a shared `CheckoutElements` group, an `ExpressCheckoutElement` (quick wallets, replacing `ApplePayButton`) and a `CardElement` (saved cards + new-card form), with the merchant owning the Pay button.

**Architecture:** Presentation-independent state (one payment lock, outcome handling, session expiry) lives in a UIKit-free `ElementsCoordinator` in `Core/Session/` so it is unit-tested on the macOS host. The public UIKit classes (`CheckoutElements`, `ExpressCheckoutElement`, `CardElement`) wrap it and compose existing internal views. The new-card form, its address forms, the save-card checkbox and their validation are extracted from `CheckoutContentViewController` into an internal `NewCardEntryView` shared by the sheet and `CardElement`. `ApplePayButton` is deleted.

**Tech Stack:** Swift 5.9, Swift Concurrency, UIKit/PassKit, XCTest, SwiftPM, Tuist demo app.

**Spec:** `docs/superpowers/specs/2026-11-12-checkout-elements-design.md` (builds on `2026-11-12-embedded-foundation-design.md`, implemented).

## Global Constraints

- AGENTS.md: Core UI-agnostic (new Core files import only Foundation); only `CardEncryptor` touches plaintext and only `CredentialStore` holds secrets; no card values, tokens, secrets or ciphertext in logs, public types, callbacks or diagnostics; payment truth is server-confirmed, no polling, no blind resubmit; `UserAction`/`CheckoutContext`/`CardInput` stay internal; English only in code and docs; small public API.
- `confirm()` has **no amount parameter**; amounts always come from the server session.
- Component configuration overrides global; **exceptions where global wins:** payment-method availability (`PaymentMethodFilter`, provider availability) and address forms (backend decides whether to collect; the host may only switch a form *off*; a component can only switch off further, never on).
- Elements render no failure/pending/unknown notice or spinner; only inline field validation errors.
- `paymentOption` content: saved card = brand image + "Visa ····4242" (server data); typed new card = brand image + localized brand name only, no digits, `nil` while empty/incomplete; Apple Pay is never a `paymentOption`.
- No git tags exist, so deleting `ApplePayButton` is not a semver break; keep `ApplePayButtonType` and `Appearance.ApplePayButtonStyle`.
- Branch `feature/checkout-elements` (cut from `main`); never develop on `main`. No commit unless the user asks; when asked, `git add` exact files, never `git add .`. The product owner allowed extra tests for this feature area.
- Verification (repo root):
  - Host: `swift build` and `swift test`.
  - iOS gate: `xcodebuild -scheme SunbayCheckout-Package -destination 'platform=iOS Simulator,id=<booted simulator id>' test > /tmp/ios-test.log 2>&1; grep -E "error: -\[|\*\* TEST" /tmp/ios-test.log | grep -v kTCC` (ids: `xcrun simctl list devices available`; a name alone is ambiguous). Known failure that also occurs on `main`: `BottomSheetLayoutTests.test_install_unmeasured_usesInitialHeightSoEntranceHasAFrame` (403.33 vs 403.5). Gate = no new failures.

## Review Focus

- Only one payment at a time across express taps and `confirm()`; a second request gets `.failed(ALREADY_PRESENTING)`. (Task 3)
- After `.pending`/`.unknown`, no further submit: `confirm()` returns the stored outcome again. (Task 3)
- After `.succeeded`: session dismissed, everything disabled, `confirm()` returns `.succeeded` without resubmitting. (Task 3)
- Session expiry makes `confirm()` return `.failed(CHECKOUT_EXPIRED)`. (Task 3)
- A hidden/unavailable method yields an element with `isAvailable == false` and a zero-height view, not a thrown error; `create` throws only for a failed/expired session load. (Tasks 1, 4, 5)
- Card element with invalid input: `confirm()` returns `.failed(CARD_INPUT_INVALID)`, nothing submitted, inline errors shown. (Task 5)
- No public type exposes card values or `CardInput`/`UserAction`. (Task 6)
- The sheet behaves exactly as before the `NewCardEntryView` extraction (all existing content tests green). (Task 2)

---

### Task 1: Driver option `failsWhenNoMethodAvailable`

**Files:**
- Modify: `Sources/SunbayCheckout/Core/Session/CheckoutSessionDriver.swift` (`DriverOptions`, `loadContext`)
- Modify: `Tests/SunbayCheckoutTests/Core/CheckoutSessionDriverTests.swift`

**Interfaces:**
- Produces: `DriverOptions.failsWhenNoMethodAvailable: Bool` (default `true`; init parameter after `expressOff`). When `false`, `loadContext()` does not return `NO_PAYMENT_METHOD_AVAILABLE` and does not call `controller.dismiss()` for an empty method list; it returns `.ready` with the empty `visibleEntries` (and `cardOnFileEnabled == false`, `savedCards == []`).

- [ ] **Step 1: Write failing tests:** `test_loadContext_noMethod_failsByDefault` (existing hide-CARD test already covers `true`; keep it) and `test_loadContext_noMethod_withFlagOff_returnsReadyWithEmptyEntries` (`PaymentMethodFilter(hide: ["CARD"])`, session methods `[.card]`; expect `.ready`, `context.visibleEntries.isEmpty`, `cof.listCallCount == 0`, and that a later `execute(.cancel)`/session is still alive: `payment.loadSessionCallCount == 1`).
- [ ] **Step 2:** `swift test --filter CheckoutSessionDriverTests` -> the new test FAILS.
- [ ] **Step 3: Implement** the flag in `DriverOptions` and branch the `guard !available.isEmpty` block on it.
- [ ] **Step 4:** `swift test --filter CheckoutSessionDriverTests` -> all pass; iOS gate -> no new failures (the sheet keeps `true`).

---

### Task 2: Extract `NewCardEntryView` from `CheckoutContentViewController`

**Files:**
- Create: `Sources/SunbayCheckout/UI/Content/Components/NewCardEntryView.swift`
- Modify: `Sources/SunbayCheckout/UI/Content/CheckoutContentViewController.swift` (card-form wiring near lines 112-140, 283-285, 624-650, 758-770, 945-975, 1217-1260, 1285-1375)
- Test: existing `Tests/SunbayCheckoutTests/UI/CheckoutContentViewControllerTests.swift` (must stay green unchanged); add `Tests/SunbayCheckoutTests/UI/NewCardEntryViewTests.swift`

**Interfaces:**
- Consumes: `CardFormView`, `DynamicAddressFormView`, `CheckboxControl`, `CardSchemeResolver`, `CardRulesRefresher`, `CardScanViewController`, `AddressCollectionMode`, `AddressFormOptions`, `CheckoutUserAction`.
- Produces (internal, `#if canImport(UIKit)`): `final class NewCardEntryView: UIView`
  - `init(appearance: ResolvedAppearance, localize: @escaping (String) -> String, localeCode: String?, sessionId: String, cardBrandItems: [CardBrandItem], cardRuleSet: CardRuleSet, cardBinService: any CardBinService, cardRulesService: any CardRulesService, billingMode: AddressCollectionMode, shippingMode: AddressCollectionMode, addressService: any AddressMetadataService, cardOnFileEnabled: Bool, saveCardByDefault: Bool, scanPresenter: @escaping () -> UIViewController?)`
  - `var onEditingChanged: (() -> Void)?`; `var isComplete: Bool` (card number/expiry/CVC form yields a valid `CardInput`); `var detectedBrandName: String?` (brand only, from the PAN prefix rules; never digits)
  - `func makeConfirmAction() -> CheckoutUserAction?`: runs exactly today's `handleConfirmNewCard` validation (card issue messages including `sunbay.card.invalid`, every shown address form validated without short-circuit, first offending address field focused) and returns `.confirmNewCard(input, save:, billing:, shipping:, billingFormShown:, shippingFormShown:)`, or `nil` when invalid.
  - `func setInteractionEnabled(_ enabled: Bool)` (card form, save checkbox, billing view, shipping container); `func clear()` (clears every field and errors); `func startBackgroundRefresh()` (calls `CardRulesRefresher.refreshInBackground`); `var billingFormShown: Bool`, `var shippingFormShown: Bool`; DEBUG seams mirroring the VC's existing ones (`fillCardForTest`, `isSaveCardRowVisible`, `billingAddressView`, `shippingAddressView`, `isSaveCardOn`, `setSaveCard`, `isCardFormInteractive`, `hasCardFieldError`).
  - The scan button is created only when `scanPresenter()` yields a view controller at tap time; with none, the tap does nothing. (In the sheet the presenter is the content VC, so behavior is unchanged.)

- [ ] **Step 1:** Run the content tests once (iOS gate) to record the green baseline.
- [ ] **Step 2: Write failing tests** in `NewCardEntryViewTests` (iOS): `test_makeConfirmAction_validCard_returnsConfirmNewCardWithSaveFlag`, `test_makeConfirmAction_incompleteCard_returnsNilAndShowsFieldError`, `test_makeConfirmAction_invalidShownAddress_returnsNilAndFocusesFirstError` (use `MockAddressService` style stub with a required postal code), `test_isComplete_followsCardValidity`, `test_detectedBrandName_isBrandOnly_noDigits` (type a Visa test number; assert the value contains no digit), `test_setInteractionEnabled_false_disablesAllInputs`, `test_clear_emptiesFieldsAndErrors`.
- [ ] **Step 3:** Run them -> FAIL (type not defined).
- [ ] **Step 4: Implement** `NewCardEntryView` by moving, not rewriting, the code from the VC: the card form, scheme resolver wiring (`onPANDigitsChanged`), the "Card information" header with the scan button, the save-card row, billing view and shipping section assembly, and the validation/assembly of `handleConfirmNewCard`.
- [ ] **Step 5:** In the VC, replace those pieces with one `newCardEntry` instance placed in `newCardStack` (keeping the top divider, section spacing and order). `handleConfirmNewCard` becomes: `guard let action = newCardEntry.makeConfirmAction(), beginProcessing() else { return }; delegate?.content(self, didRequest: action)`. Keep every `...ForTest` accessor of the VC as a forwarding property to the entry view; `setInputsEnabled` calls `newCardEntry.setInteractionEnabled`; `refreshConfirmButtonState` uses `newCardEntry.isComplete`; `viewDidLoad` calls `newCardEntry.startBackgroundRefresh()`; `scanPresenter` returns `self`.
- [ ] **Step 6:** Run `NewCardEntryViewTests` -> pass; run the full iOS gate -> no new failures (the 87+ content tests unchanged and green; this is the proof the sheet is unaffected).

---

### Task 3: `ElementsCoordinator` (Core) and the driver additions it needs

**Files:**
- Create: `Sources/SunbayCheckout/Core/Session/ElementsCoordinator.swift`
- Create: `Tests/SunbayCheckoutTests/Core/ElementsCoordinatorTests.swift`
- Modify: `Sources/SunbayCheckout/Core/Session/CheckoutSessionDriver.swift`

**Interfaces:**
- Consumes: `CheckoutSessionDriver`, `CheckoutUserAction`, `CheckoutErrors`.
- Produces on the driver: `func dismiss() async`, `func updateHostAddresses(billing: AddressInput?, shipping: AddressInput?) async`, `func walletContactRequest() async -> WalletContactRequest` (flags `false, false`).
- Produces: `@MainActor final class ElementsCoordinator` with
  - `enum State: Equatable { case ready, confirming, finished(CheckoutOutcome), expired }`
  - `init(driver: CheckoutSessionDriver, context: CheckoutSessionContext, sleep: @escaping @Sendable (TimeInterval) async -> Void = { try? await Task.sleep(nanoseconds: UInt64($0 * 1_000_000_000)) })`
  - `private(set) var state: State`; `let context: CheckoutSessionContext`; `var onStateChange: ((State) -> Void)?`
  - `func run(_ body: () async -> CheckoutOutcome) async -> CheckoutOutcome`: if `state == .confirming` -> `.failed(txnId: nil, error: CheckoutErrors.alreadyPresenting())`; if `.finished(outcome)` -> `outcome` (no body call); if `.expired` -> `.failed(txnId: nil, error: CheckoutErrors.sessionExpired())`; otherwise set `.confirming`, await `body()`, then map: `.succeeded` -> `.finished` + `await driver.dismiss()`; `.pending`/`.unknown` -> `.finished(outcome)`; `.failed`/`.canceled` -> `.ready`; return the outcome.
  - `func perform(_ action: CheckoutUserAction) async -> CheckoutOutcome` = `run { switch await driver.execute(action) { case let .outcome(o), let .startFailed(o): return o } }`.
  - `func startExpiryTimer()`: sleeps until `context.session.expiresAt`; when it fires while not finished: state `.expired`, `await driver.dismiss()`. `func close() async`: cancels the timer, dismisses once, state stays/ becomes `.finished(.canceled)` only if not already finished. Idempotent.

- [ ] **Step 1: Write failing tests** (host, `ScriptablePayment/Cof` mocks as in the driver tests): `test_perform_savedCard_succeeded_finishesAndDismisses`, `test_perform_failed_returnsToReady_andAllowsRetry` (second perform submits again, `submitCallCount == 2`), `test_perform_pending_locksAndReturnsStoredOutcome_withoutResubmit` (`submitCallCount == 1` after two calls), `test_perform_unknown_locks`, `test_secondRunWhileConfirming_returnsAlreadyPresenting` (use a suspended `body` via a continuation), `test_afterSucceeded_runReturnsSucceededWithoutBody`, `test_expiry_whenTimerFires_marksExpired_andRunReturnsCheckoutExpired` (inject a `sleep` that returns immediately), `test_expiry_doesNotOverrideFinishedState`, `test_close_dismissesOnce_andIsIdempotent`, `test_onStateChange_reportsTransitions`.
- [ ] **Step 2:** `swift test --filter ElementsCoordinatorTests` -> FAIL.
- [ ] **Step 3: Implement** the coordinator and the three driver methods (thin forwards to the controller: `dismiss`, `updateHostAddresses`, `walletContactRequest(billingFormShown: false, shippingFormShown: false)`).
- [ ] **Step 4:** `swift test` -> all pass (host).

---

### Task 4: `CheckoutElements`, `ExpressCheckoutElement`, and removal of `ApplePayButton`

**Files:**
- Create: `Sources/SunbayCheckout/UI/Elements/CheckoutElements.swift`, `.../UI/Elements/ExpressCheckoutElement.swift`, `.../UI/Elements/PaymentOptionDisplayData.swift`
- Modify: `Sources/SunbayCheckout/Public/SunbayCheckout.swift` (one internal factory for the wiring now duplicated in `PaymentSheet`/`ApplePayButton`; doc comments mentioning `ApplePayButton`)
- Modify: `Sources/SunbayCheckout/UI/Content/Components/ExpressCheckoutView.swift` (accept optional button type/style overrides; move the pure `pkStyle(for:trait:)` mapping here from `ApplePayButton`)
- Delete: `Sources/SunbayCheckout/UI/Wallet/ApplePayButton.swift`
- Replace: `Tests/SunbayCheckoutTests/UI/ApplePayButtonTests.swift` -> `ExpressCheckoutElementTests.swift`; `ApplePayButtonStyleTests.swift` -> point at the moved mapping
- Modify: `Example/SunbayCheckoutDemo/Sources/DemoRootView.swift` (+ `DemoApp.swift`, `DemoSettings.swift` comments), `Example/README.md`

**Interfaces:**
- Consumes: Task 3 coordinator and driver additions; `WalletAuthorizing`, `ApplePayAvailability`, `ExpressCheckoutView`.
- Produces (public, `@MainActor`, UIKit-gated): as specified in the design (`CheckoutElements.create(checkout:sessionId:configuration:)`, `makeExpressCheckoutElement(_:)`, `makeCardElement(_:)` (stubbed to return an unavailable element until Task 5), `paymentOption`, `confirm()`, `retrievePayment()`, `updateAddresses(billing:shipping:)`, `close()`; `ExpressCheckoutElement` with `Configuration { methods: Set<ExpressMethod>?, buttonType: ApplePayButtonType?, buttonStyle: Appearance.ApplePayButtonStyle? }`, `view`, `isAvailable`, `onAvailabilityChange`, `onResult`; `PaymentOptionDisplayData`).
- `create` builds the driver with `DriverOptions(expressOff: appearance.expressPosition == .off, failsWhenNoMethodAvailable: false, addressFormsShown: ...)` exactly as `PaymentSheet.init` builds the closure, calls `loadContext()`, throws the `CheckoutError` of a `.startFailed(.failed)` (or a `SESSION_LOAD_FAILED`-style error for `.unknown`), creates the coordinator and calls `startExpiryTimer()`.

- [ ] **Step 1: Write failing tests** `ExpressCheckoutElementTests` migrated from the 8 `ApplePayButtonTests` cases against the new API (iOS; stub `WalletAuthorizing` injected through an internal `CheckoutElements.create` overload taking the controller/services, like the old internal init): available when device+merchant id+session allow; unavailable and `onAvailabilityChange(false)` when `PaymentMethodFilter(hide: ["APPLE_PAY"])`; tap -> `onResult(.succeeded)`; wallet cancel -> `.canceled`; auth failure -> `.failed`; `updateAddresses` reaches the controller; contacts requested from the controller and returned addresses submitted; missing wallet parameters -> unavailable plus one names-only warning. Add: `test_methodsApplePayOnly_showsOnlyApplePay`, `test_noApplePayAvailable_isUnavailable_andViewHasZeroHeight`, `test_tap_whileAnotherPaymentInFlight_reportsAlreadyPresenting`, `test_createWithAllMethodsHidden_doesNotThrow` and `test_createWithSessionLoadFailure_throwsCheckoutError`. Move the three `pkStyle` tests to the new location.
- [ ] **Step 2:** Run them -> FAIL.
- [ ] **Step 3: Implement** the three public types, the factory on `SunbayCheckout` (extract the shared wiring: controller via `makeController`, `CredentialStore`, `ActionHandler(webAuthOpener:)`, `LocalizationResolver`, `resolveMerchantId`, `screenMetrics`), and let `PaymentSheet` use the same factory without changing behavior. The express tap runs `coordinator.run { authorize... }` where the authorizer's confirm closure calls `driver.execute(.confirmWallet(authorization, billingFormShown: false, shippingFormShown: false))` and the thrown-error mapping is copied from the old `ApplePayButton.handleTap` (`WALLET_CANCELED` -> `.canceled`, otherwise `WALLET_AUTH_FAILED`). Delegate the button rendering to `ExpressCheckoutView` (`showsDivider: false`). Record `screenMetrics` main screen at creation and refresh in `didMoveToWindow`.
- [ ] **Step 4:** Delete `ApplePayButton.swift`, fix remaining references (`SunbayCheckout.swift` comments, `ExpressCheckoutView` comment, demo, README). In the demo replace the "Standalone ApplePayButton" section with an "Elements" section that creates `CheckoutElements` for the current session and shows the Express element with a log of `onResult`.
- [ ] **Step 5:** `swift build`, `swift test`, iOS gate -> no new failures; build the demo (Tuist-generated project) if available: `xcodebuild -scheme SunbayCheckoutDemo -destination 'generic/platform=iOS Simulator' build` -> `BUILD SUCCEEDED`.

---

### Task 5: `CardElement`

**Files:**
- Create: `Sources/SunbayCheckout/UI/Elements/CardElement.swift`
- Modify: `Sources/SunbayCheckout/UI/Elements/CheckoutElements.swift` (`makeCardElement`, `confirm()`, `paymentOption`)
- Test: `Tests/SunbayCheckoutTests/UI/CardElementTests.swift`

**Interfaces:**
- Consumes: Task 2 `NewCardEntryView`, Task 3 coordinator, `SavedCardSelection`, `SavedCardRow`.
- Produces (public): `CardElement` with `Configuration { showsSavedCards: Bool?, billingAddress: AddressMode?, shippingAddress: AddressMode?, showsSaveCardOption: Bool? }`, `enum AddressMode { case automatic, off }`, `view`, `isAvailable`, `isComplete`, `delegate: CardElementDelegate?` (`cardElementDidUpdateHeight(_:)`, `cardElementDidChangeSelection(_:)` default no-op), `clear()`. `CheckoutElements.confirm()` pays the card element's selection.
- Composition: saved-card rows (radio-style selection through `SavedCardSelection`, expired dimmed and not selectable, default = first usable) + a "New card" row that expands `NewCardEntryView` inline; with no saved cards the form is shown directly. The new-card entry is built with the effective address modes (global resolved first, then the component's `.off` applied) and COF flags. `isAvailable == false` when CARD is hidden/absent: zero-height view, no form.
- `paymentOption`: saved card selected -> label "Visa ····4242" + brand image (`SavedCardRow` logo loader); new card active -> localized brand name + brand image only, `nil` while `!isComplete`; else `nil`.
- `confirm()`: no card element or no selection -> `.failed(NO_PAYMENT_OPTION_SELECTED)`; saved card -> `coordinator.perform(.confirmSavedCard)`; new card -> `makeConfirmAction()` (nil -> `.failed(CARD_INPUT_INVALID)`, nothing submitted) then `coordinator.perform`. While locked `setInteractionEnabled(false)`; after `.succeeded` clear the form and disable the element. Self-sizing (`intrinsicContentSize`, invalidated on content change, `cardElementDidUpdateHeight`). Focused field scrolls into view inside the nearest ancestor `UIScrollView`.

- [ ] **Step 1: Write failing tests** (iOS): `test_savedCards_defaultSelectsFirstUsable_andPaymentOptionIsServerLabel`, `test_expiredSavedCard_notSelectable`, `test_noSavedCards_showsFormDirectly`, `test_typedCard_paymentOptionIsBrandOnly_noDigits`, `test_confirm_savedCard_submitsConfirmSavedCard`, `test_confirm_newCardValid_submitsEncryptedCard_once` (assert `submitCallCount == 1`), `test_confirm_invalidCard_returnsCardInputInvalid_andDoesNotSubmit`, `test_confirm_noSelection_returnsNoPaymentOptionSelected`, `test_confirm_failed_keepsFormForRetry_secondConfirmSubmitsAgain`, `test_confirm_succeeded_clearsFormAndDisables`, `test_confirm_pending_staysLocked_returnsStoredOutcome`, `test_addressMode_off_hidesForm_butCannotForceOnWhenGlobalOff`, `test_cardHiddenByFilter_isUnavailable_zeroHeight`, `test_inputsDisabledWhileConfirming`, `test_heightCallback_firesWhenSelectionExpandsForm`.
- [ ] **Step 2:** Run -> FAIL.
- [ ] **Step 3: Implement** `CardElement` and wire `CheckoutElements.confirm()`/`paymentOption`; the group delegates availability and the card-element selection to the card element it created (one `CardElement` per group: a second `makeCardElement` call returns the same instance or fails with an assertion, per the builder's choice, documented).
- [ ] **Step 4:** Run the new tests -> pass; iOS gate -> no new failures.

---

### Task 6: Public-surface check, demo, docs

**Files:**
- Create: `Tests/SunbayCheckoutTests/UI/ElementsPublicSurfaceTests.swift`
- Modify: `Example/SunbayCheckoutDemo/Sources/DemoRootView.swift` (Elements screen with a host-owned Pay button + card + express)
- Modify: `docs/product-spec.md`, `docs/capabilities-report.md`, `docs/security-and-pci.md`, `docs/real-api-integration-checklist.md` if any new open item, `Example/README.md`, integration notes (keyboard insets are the host's job, one `CardElement` per group, Express vs Card flow, pending/unknown handling, `confirm()` semantics)

- [ ] **Step 1: Write the surface test:** use `Mirror` on instances of `CheckoutElements`, `ExpressCheckoutElement`, `CardElement` and `PaymentOptionDisplayData` to assert no stored public-reachable property has a type whose name contains `CardInput`, `CheckoutUserAction`, `WalletAuthorization`, or `String` values equal to a typed PAN after typing a test card (type the number into the element's view tree, then assert the PAN string appears in no `Mirror`-reachable public property, `paymentOption.label`, or `String(describing:)` of the public objects). Run -> expect pass (it protects against regressions).
- [ ] **Step 2:** Build the demo Elements screen: `CheckoutElements.create` for the current session, `makeExpressCheckoutElement`, `makeCardElement`, a host "Pay" `Button` that calls `confirm()` and logs the outcome, a toggle for Apple Pay only, and a "Close" action.
- [ ] **Step 3:** Docs: add the Elements chapter to `product-spec.md` and `capabilities-report.md` (L2 is now Elements); in `security-and-pci.md` add the inline-card-field exposure (merchant code in the same process can traverse the view hierarchy; we expose no read API; part of the host app's PCI scope), the cleanup list, the "released and cleared, not erased" wording and a **release-gate** item for QSA/acquirer confirmation (fallback: `PaymentSheet`); remove every `ApplePayButton` mention.
- [ ] **Step 4:** Final checks: `swift build`, `swift test`, iOS gate, demo build -> all as in Global Constraints; `grep -rn "ApplePayButton" Sources Example docs/product-spec.md docs/capabilities-report.md README.md` shows only `ApplePayButtonType`/`ApplePayButtonStyle` uses.

---

## Self-Review Notes

- Spec coverage: components and API (Tasks 4-5), shared lock/expiry/outcome semantics (Task 3), no-method-available handling (Task 1), `NewCardEntryView` extraction with sheet unchanged (Task 2), `ApplePayButton` removal and demo/docs migration (Tasks 4, 6), security wording and release gate (Task 6), config precedence exceptions (Task 5 test `test_addressMode_off_hidesForm_butCannotForceOnWhenGlobalOff`, Task 4 availability tests).
- Names are consistent across tasks: `ElementsCoordinator.run/perform/startExpiryTimer/close`, `DriverOptions.failsWhenNoMethodAvailable`, `NewCardEntryView.makeConfirmAction/isComplete/setInteractionEnabled/clear`.
- Largest risk: Task 2 (moving code the content tests pin). It ends with the full iOS gate; if a seam cannot be forwarded, stop and rule rather than rewrite the sheet's tests (the spec forbids that).
