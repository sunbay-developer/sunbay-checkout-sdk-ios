# Address Unification, Postal Validation and Payment-Failure Fixes Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Show the real payment-failure reason, keep the PaymentSheet open after a failed card payment, and make the simple address form reuse the full form with backend-driven, blocking postal-code validation.

**Architecture:** (1) Decode `failureReason` into `PaymentSnapshot` and surface it as the `CheckoutError.message`. (2) Load the session once per presentation instead of once per attempt, so a failed attempt can no longer end the presentation through a reload failure. (3) Add `visibleFields` and `validate()` to `DynamicAddressFormView`, drive "simple" through it, delete `SimpleAddressFormView`, and gate the new-card confirm on `validate()`. A pure `PostalCodeValidator` and a `FallbackAddressMetadataService` live in Core.

**Tech Stack:** Swift 5.9, UIKit, XCTest (host `swift test` + iOS Simulator `xcodebuild test`), Tuist demo app.

**Spec:** `docs/superpowers/specs/2026-11-10-address-form-unification-and-postal-validation-design.md` (address work, Tasks 3–7). Tasks 1–2 are covered by "Additional scope decisions" below (the user approved fixing both, 2026-11-10).

## Additional scope decisions (Tasks 1–2; my calls, flagged for review)

- Root cause evidence for the sheet closing: `present()` returns `.failed` to the host only via the `.startFailed` branch (`outcomeOnClose` maps a user close after `.failed` to `.canceled`). The Demo showing `Payment failed: <code>` therefore means the per-attempt session reload (`runAttempt` → `controller.start` → `loadSession`) threw after the failed payment. The reload also set `controller.session = nil` first. Fix: load once, reuse the context.
- Cost of that fix: no session-expiry re-check between attempts. A submit on an expired session is rejected by the backend and shown inline, which is acceptable.
- `failureReason` becomes `CheckoutError.message` with the existing code `PAYMENT_FAILED` (host-visible code unchanged). The localized generic string for `payment_failed` must not override a server reason.
- "No message in the log" is fixed in the Demo app log and toast. The SDK still has no logger and terminal failures are still not mirrored as diagnostics (`product-spec.md` lines 161-162 stay as they are).

## Global Constraints

- Swift only; English only in code, comments, strings in code, test names and docs (AGENTS.md §2.2). zh-Hans `.strings` values are Chinese by design.
- Core imports no UIKit/PassKit (AGENTS.md §2.6). `PostalCodeValidator` and `FallbackAddressMetadataService` are Foundation-only.
- Card values, tokens, secrets, postal codes and addresses are never logged or put in diagnostics (AGENTS.md §2.3, product-spec address section).
- Do not develop on `main`. Do not commit unless the user explicitly asks; never `git add .`. Leave the unrelated untracked card-brand-icons files and `Example/README.md` alone.
- Do not add tests beyond those listed; update tests whose logic changes.
- Public API stays additive: `PaymentSnapshot.init(sessionId:status:txnId:failureReason:)` gains a defaulted parameter.
- Test commands: host `swift test`; UIKit `xcodebuild test -scheme SunbayCheckout-Package -destination 'platform=iOS Simulator,name=iPhone 17 Pro'` (append `-only-testing:SunbayCheckoutTests/<Class>` to filter).

## Review Focus

1. Metadata endpoint down in simple mode: user must still be able to pay with a non-empty postal code; an empty one is blocked with the required message (Task 5).
2. Country changed after a postal code was typed for the old country: the field is re-validated against the new country and shows the error (Task 4).
3. A country whose config has no `postalCode` field: no field, no error, and a stale postal code from the previous country must not be sent (Task 4).
4. Backend `pattern` that does not compile as a regex: no crash, no block (Task 3).
5. Blank or whitespace-only `failureReason`: fall back to the default message, never show an empty notice (Task 1).

## File Structure

- Create `Sources/SunbayCheckout/Core/AddressMetadata/PostalCodeValidator.swift` – pure rule evaluation.
- Create `Sources/SunbayCheckout/Core/AddressMetadata/FallbackAddressMetadataService.swift` – decorator, system countries + generic config on failure.
- Modify `Sources/SunbayCheckout/UI/Content/Components/DynamicAddressFormView.swift` – `visibleFields`, `validate()`, error label, test seams.
- Modify `Sources/SunbayCheckout/UI/Content/CheckoutContentViewController.swift` – simple mode via Dynamic, confirm gate.
- Delete `Sources/SunbayCheckout/UI/Content/Components/SimpleAddressFormView.swift`.
- Modify `Core/ContractDecoding.swift`, `Core/Models/PaymentSnapshot.swift`, `Core/CheckoutController.swift`, `Core/Localization/CheckoutErrorLocalization.swift` – failure reason.
- Modify `UI/PaymentSheet/PaymentSheet.swift` – load once.
- Modify `Resources/Localizations/{en,zh-Hans}.lproj/Localizable.strings`.
- Modify `Example/SunbayCheckoutDemo/Sources/DemoRootView.swift`.
- Docs: `docs/product-spec.md`, `docs/real-api-integration-checklist.md`.

---

### Task 1: Show the real payment-failure reason

**Files:**
- Modify: `Sources/SunbayCheckout/Core/Models/PaymentSnapshot.swift`, `Sources/SunbayCheckout/Core/ContractDecoding.swift` (`ResultWire`, `toEnvelope`), `Sources/SunbayCheckout/Core/CheckoutController.swift` (`CheckoutErrors.paymentFailed`, `mapSnapshot`), `Sources/SunbayCheckout/Core/Localization/CheckoutErrorLocalization.swift`, `Example/SunbayCheckoutDemo/Sources/DemoRootView.swift` (outcome handling near line 491)
- Test: `Tests/SunbayCheckoutTests/Core/ContractCodableTests.swift`, `Tests/SunbayCheckoutTests/Core/CheckoutControllerTests.swift`, `Tests/SunbayCheckoutTests/Core/CheckoutErrorLocalizationTests.swift`

**Interfaces:**
- Produces: `PaymentSnapshot.failureReason: String?`; `CheckoutErrors.paymentFailed(reason: String? = nil) -> CheckoutError`; `CheckoutErrors.defaultPaymentFailedMessage: String` (`"The payment failed."`).

- [ ] **Step 1: Create the branch** `git switch -c fix/address-postal-validation-and-payment-errors` (from `main`; leave the existing untracked files alone).
- [ ] **Step 2: Write failing tests**
  - `ContractCodableTests.test_resultWithFailureReason_decodesIntoSnapshot`: `{"txnId":"t1","txnStatus":"F","failureReason":"Insufficient funds"}` → `snapshot.failureReason == "Insufficient funds"`; same JSON without the key → `nil`.
  - `CheckoutControllerTests.test_failedSnapshotWithReason_usesReasonAsMessage_keepsCode`: submit returns `.failed` with `failureReason: "Card declined"` → `.failed(txnId:, error:)` with `error.code == "PAYMENT_FAILED"`, `error.message == "Card declined"`.
  - `CheckoutControllerTests.test_failedSnapshotWithBlankReason_usesDefaultMessage`: reasons `nil`, `""`, `"   "` → `error.message == CheckoutErrors.defaultPaymentFailedMessage`.
  - `CheckoutErrorLocalizationTests.test_paymentFailedWithServerReason_displaysReason`: `CheckoutError(code: "PAYMENT_FAILED", message: "Card declined", ...)` → `localizedDisplayMessage` returns `"Card declined"`; with the default message it still returns the localized `sunbay.error.payment_failed` string.
- [ ] **Step 3: Run `swift test --filter 'ContractCodableTests|CheckoutControllerTests|CheckoutErrorLocalizationTests'`** – Expected: FAIL (symbols missing).
- [ ] **Step 4: Implement** the interface above. `ResultWire` gets `let failureReason: String?`; `toEnvelope` passes it to the snapshot; `mapSnapshot` `.failed` uses `CheckoutErrors.paymentFailed(reason: snapshot.failureReason)` (trim, empty → default). `localizedDisplayMessage`: when `code == "PAYMENT_FAILED"` and `message != CheckoutErrors.defaultPaymentFailedMessage`, return `message` before the key lookup.
- [ ] **Step 5: Demo.** In `DemoRootView` outcome handling, the `.failed` toast becomes `"Payment failed: \(error.message) (\(error.code))"`, and every `.failed` also calls `log.add("Payment failed: code=\(error.code) message=\(error.message) traceId=\(error.traceId ?? "-")", level: .error)`. Log lines for the other outcomes are not required.
- [ ] **Step 6: Run `swift test`** – Expected: 0 failures. Build the demo: `cd Example/SunbayCheckoutDemo && tuist generate --no-open && xcodebuild -workspace SunbayCheckoutDemo.xcworkspace -scheme SunbayCheckoutDemo -destination 'generic/platform=iOS Simulator' build` – Expected: BUILD SUCCEEDED.

---

### Task 2: Keep the sheet open after a failed card payment

**Files:**
- Modify: `Sources/SunbayCheckout/UI/PaymentSheet/PaymentSheet.swift` (`runAttempt`, `present`, doc comments)
- Test: `Tests/SunbayCheckoutTests/UI/PaymentSheetRunCheckoutTests.swift`

**Interfaces:**
- Produces: `PaymentSheet.loadContext() async -> ContextResult` where `enum ContextResult { case ready(CheckoutContext); case startFailed(CheckoutOutcome) }` (steps 1–2 of today's `runAttempt`, unchanged behavior). `runAttempt(seam:)` keeps its signature and meaning (`loadContext` → `seam` → `execute`) so existing `runCheckout`/`runAttempt` tests stay valid.

- [ ] **Step 1: Write failing tests** (simulator, using the existing `presentSheet` helper in this file):
  - `test_failedConfirm_keepsSheetOpen_andDoesNotReloadSession`: submit `[failed, ok]`; pay → failed state shown; assert `payment.loadSessionCallCount == 1`; tap Pay again → outcome `.succeeded(txnId: "txn_2")`, `submitCallCount == 2`.
  - `test_failedConfirm_thenLoadWouldFail_stillKeepsSheetOpen`: same, with `payment.stubLoadError(CheckoutErrors.networkUnavailable())` set after the first present; the sheet must still be showing the failed state 300 ms later and a close returns `.canceled`.
  - `test_pendingConfirm_doesNotReload_closeReturnsPending`: replaces `test_startFailureWhileLocked_doesNotUnlock_returnsUnresolvedOutcome` (same assertions on `.reconciling` and `.pending(txnId: nil)`, no reload involved).
- [ ] **Step 2: Run** `xcodebuild test ... -only-testing:SunbayCheckoutTests/PaymentSheetRunCheckoutTests` – Expected: the new tests FAIL (the reload happens today), proving the root cause.
- [ ] **Step 3: Implement** `loadContext`; in `present()` call it once before the loop (`.startFailed` → `coordinator.dismiss()` and return it, exactly as today's first-load failure), then loop `action = await coordinator.awaitNextAction(context:)` → `execute(action)` → `applyOutcome`. Remove the now-dead branch that waits for an event after a `.startFailed` while `isUnresolved`. Keep `isUnresolved`, `outcomeOnClose` and the cancel handling as they are. Update the doc comments of `present()` ("Retry loop", "Pending / unknown and start failures") to say the session loads once per presentation.
- [ ] **Step 4: Rewrite the tests that pinned the reload** (they are obsolete by design): delete `test_reloadFailureAfterConfirmedFailure_endsWithStartFailure`; rewrite `test_tapDuringUnlockWindow_isBuffered_notDropped` and `test_closeWinsOverBufferedTap` to their invariants without a reload window (a tap right after a failure submits attempt 2; a close right after a failure returns `.canceled` and submits nothing). Keep `test_firstLoadFailure_returnsFailure_doesNotHotLoop` unchanged.
- [ ] **Step 5: Run the file's tests, then the full simulator suite** – Expected: 0 failures.
- [ ] **Step 6: Manual check on dev** (cannot be automated): run the Demo against `.dev`, pay with a declining test card. Expected: the sheet stays open, the red inline notice shows the backend `failureReason` (or the backend `msg`), and the Demo log shows code/message/traceId. Report the observed text. If the sheet still closes, stop and report the Demo log line; do not guess a further fix.

---

### Task 3: `PostalCodeValidator`

**Files:**
- Create: `Sources/SunbayCheckout/Core/AddressMetadata/PostalCodeValidator.swift`
- Test: `Tests/SunbayCheckoutTests/Core/PostalCodeValidatorTests.swift`

**Interfaces:**
- Produces: `enum PostalCodeValidationResult: Equatable { case valid, required, invalidFormat }` and `enum PostalCodeValidator { static func validate(_ value: String?, config: AddressFieldConfig?) -> PostalCodeValidationResult }`.

- [ ] **Step 1: Write failing tests** (US-style `pattern: "^[0-9]{5}(-[0-9]{4})?$"`):
  - `config == nil` → `.valid` for `nil`, `""` and `"abc"`.
  - `required: true, pattern: nil`: `""`/`nil`/`"  "` → `.required`; `"anything"` → `.valid`.
  - `required: false, pattern: US`: `""` → `.valid`; `"94103"` and `" 94103 "` → `.valid`; `"9410"` and `"94103x"` → `.invalidFormat`.
  - `required: true, pattern: US`: `""` → `.required`; `"abcde"` → `.invalidFormat`.
  - `pattern: "([unclosed"` (does not compile), `required: false`: `"x"` → `.valid`.
  - Pattern without anchors, `"[0-9]{5}"`: `"123456"` → `.invalidFormat` (the whole trimmed value must match).
- [ ] **Step 2: Run** `swift test --filter PostalCodeValidatorTests` – Expected: FAIL.
- [ ] **Step 3: Implement** per the spec rules: trim whitespace; empty → `.required` iff `config.required`, else `.valid`; non-empty with a pattern → compile with `NSRegularExpression` (failure → `.valid`), match must cover the full trimmed range; otherwise `.valid`.
- [ ] **Step 4: Run** the filter – Expected: PASS.

---

### Task 4: `DynamicAddressFormView` – `visibleFields` and `validate()`

**Files:**
- Modify: `Sources/SunbayCheckout/UI/Content/Components/DynamicAddressFormView.swift` (init, `rebuildFields`, `makeField`, `addressInput`, `selectCountry`, doc comment lines 20-21)
- Modify: `Sources/SunbayCheckout/Resources/Localizations/en.lproj/Localizable.strings`, `zh-Hans.lproj/Localizable.strings`
- Test: `Tests/SunbayCheckoutTests/UI/DynamicAddressFormViewTests.swift`

**Interfaces:**
- Consumes: `PostalCodeValidator.validate(_:config:)`.
- Produces: `init(appearance:localize:service:locale:options:visibleFields: Set<AddressFieldType>? = nil)`; `func validate() -> Bool`; DEBUG seams `postalErrorMessageForTest: String?`, `selectCountryForTest(_:)` (exists), `setPostalCodeForTest(_:)` (exists), `fillForTest(country:line1:postalCode:firstName:lastName:phone:)` (moved from `SimpleAddressFormView`; sets the model directly then re-applies), `hasNameFieldsForTest: Bool`, `hasPhoneFieldForTest: Bool`.
- Strings: `sunbay.address.postalCode.required` ("Enter a postal code." / "请输入邮政编码。"), `sunbay.address.postalCode.invalid` ("Enter a valid postal code." / "请输入有效的邮政编码。").

- [ ] **Step 1: Write failing tests** (services defined in the test file; US config `required: true, pattern: "^[0-9]{5}$"`, a second country `HK` whose config has no `postalCode` field and `layout` without it):
  - `test_visibleFields_filtersRows`: `visibleFields: [.country, .line1, .postalCode]` over a config with city/state → only line1 and postal rendered; `addressInput.city == nil`.
  - `test_visibleFields_keepsNameFieldsWhenCollected`: shipping options + `[.country, .line1, .postalCode, .firstName, .lastName]` → names rendered; billing options → not.
  - `test_validate_invalidPostal_returnsFalse_andShowsInvalidMessage`: `"1234"` → `false`, `postalErrorMessageForTest == "sunbay.address.postalCode.invalid"` (localize is `{ $0 }`).
  - `test_validate_emptyRequiredPostal_showsRequiredMessage`.
  - `test_validate_validPostal_returnsTrue_andClearsError`.
  - `test_countryChange_revalidatesTypedPostal`: US with `"94103"` valid; switch to a country whose pattern is `^[A-Z][0-9][A-Z] ?[0-9][A-Z][0-9]$` → the error message appears without calling `validate()` again.
  - `test_countryWithoutPostalField_noError_andNoStalePostalInInput`: type `"94103"` under US, switch to `HK` → `validate() == true`, `addressInput.postalCode == nil`.
  - `test_validate_returnsTrue_whileLoadingOrFailed`: service that throws → `validate() == true` (metadata unavailable never blocks here).
- [ ] **Step 2: Run** `-only-testing:SunbayCheckoutTests/DynamicAddressFormViewTests` – Expected: FAIL.
- [ ] **Step 3: Implement.** `visibleFields` filters the resolver output (drop fields not in the set, drop empty rows; the country row is always rendered). Error label under the postal field (danger color, `appearance.cardFieldFont`-based small font, hidden when empty), plus `setErrorActive(true/false)` on the field; the error clears when the user edits. After a country change and rebuild, re-validate if the postal field has text or an error was showing. `addressInput` returns `postalCode == nil` when the current config has no postal field. Fix the class doc comment so it describes the real behavior.
- [ ] **Step 4: Add the two strings** to both `.strings` files; run `-only-testing:SunbayCheckoutTests/LocalizationKeyCoverageTests` – Expected: PASS.
- [ ] **Step 5: Run** the `DynamicAddressFormViewTests` – Expected: PASS.

---

### Task 5: `FallbackAddressMetadataService`

**Files:**
- Create: `Sources/SunbayCheckout/Core/AddressMetadata/FallbackAddressMetadataService.swift`
- Test: `Tests/SunbayCheckoutTests/Core/FallbackAddressMetadataServiceTests.swift`

**Interfaces:**
- Produces: `struct FallbackAddressMetadataService: AddressMetadataService { init(wrapping: any AddressMetadataService, labels: Labels) }` with `struct Labels: Sendable { let firstName, lastName, line1, postalCode: String }`.
- Behavior: `countries(locale:)` – inner success returns it unchanged; on any throw returns `Locale.isoRegionCodes` as `AddressCountry` sorted by localized name (using `Locale(identifier: locale ?? Locale.current.identifier)`) and `detectedCountry = Locale.current.region?.identifier`. `countryConfig(countryCode:locale:)` – inner success returns it; on throw returns code, `layout: [[.firstName, .lastName], [.line1], [.postalCode]]`, `fields` with `line1` (`required: false`), `postalCode` (`required: true`, `pattern: nil`), names (`required: false`), each `label`/`placeholder` = the matching `Labels` value, `subdivisions: []`.

- [ ] **Step 1: Write failing tests** with a throwing inner service and a succeeding one: success passes through untouched (both calls); failure returns a non-empty, name-sorted country list containing `US`; failure config has the three-row layout, postal `required == true && pattern == nil`, and labels equal to the injected ones.
- [ ] **Step 2: Run** `swift test --filter FallbackAddressMetadataServiceTests` – Expected: FAIL; implement; run again – Expected: PASS.

---

### Task 6: Simple mode uses the full form; confirm is gated

**Files:**
- Modify: `Sources/SunbayCheckout/UI/Content/CheckoutContentViewController.swift` (`makeAddressView` ~line 1285, `handleConfirmNewCard` ~line 586, `formAddress(from:)`)
- Delete: `Sources/SunbayCheckout/UI/Content/Components/SimpleAddressFormView.swift`
- Test: `Tests/SunbayCheckoutTests/UI/CheckoutContentViewControllerTests.swift`, `Tests/SunbayCheckoutTests/UI/Snapshots/CheckoutContentSnapshotTests.swift` (if affected)

**Interfaces:**
- Consumes: Tasks 3–5.

- [ ] **Step 1: Write failing tests** in `CheckoutContentViewControllerTests` (use a service with US `required: true, pattern: "^[0-9]{5}$"`):
  - `test_simpleBilling_invalidPostal_blocksConfirm`: fill the card, set postal `"1234"`, tap Pay → `delegate.action == nil`, the billing form shows the invalid message, state stays `.editing`.
  - `test_simpleBilling_validPostal_confirms`: postal `"94103"` → `.confirmNewCard` with `billing.postalCode == "94103"`.
  - `test_bothFormsInvalid_showBothErrors_noConfirm`: billing and shipping simple, both invalid.
  - `test_simpleBilling_metadataDown_nonEmptyPostalConfirms_emptyBlocked`: throwing service → fallback; postal `"12345"` confirms; empty postal is blocked with the required message.
  - `test_savedCardAndWallet_notGatedByAddressValidation`: saved-card confirm with an invalid billing form still submits.
- [ ] **Step 2: Run** the class on the simulator – Expected: new tests FAIL.
- [ ] **Step 3: Implement.** `.simple` builds `DynamicAddressFormView(... service: FallbackAddressMetadataService(wrapping: addressService, labels: <localized first/last/line1/postal titles>), visibleFields: [.country, .line1, .postalCode, .firstName, .lastName])`; `.full` is unchanged. In `handleConfirmNewCard`, after the card check and before `beginProcessing()`, call `validate()` on every present address view without short-circuiting; any `false` → return. Drop the `SimpleAddressFormView` case from `formAddress(from:)` and delete the file.
- [ ] **Step 4: Fix existing tests** that referenced `SimpleAddressFormView` (`test_pay_noBillingForm_sendsShippingFormValues_andNilBilling`, `test_simpleShippingShowsNameRow_simpleBillingDoesNot`): cast to `DynamicAddressFormView`, call `waitForLoadForTest()` first, and use the moved seams. Tests whose service fixtures have `required: true` for postal and pay without a postal code must either fill a valid one or use a fixture with `required: false` – prefer the fixture change (the intent of those tests is not postal validation).
- [ ] **Step 5: Run the full simulator suite and `swift test`** – Expected: 0 failures. Record any snapshot differences and re-record only if the change is the intended error-label/simple-form difference; report which.

---

### Task 7: Docs and final verification

**Files:**
- Modify: `docs/product-spec.md` (address section lines ~275-305, §2.2/state text if it mentions reload), `docs/real-api-integration-checklist.md`, `docs/superpowers/specs/2026-11-03-checkout-sdk-ui-redesign-design.md` (lines 320-322 and 517-518: add a "superseded by 2026-11-10" note)

- [ ] **Step 1: product-spec.** `.simple` description: "country / line1 / postal code, rendered by the same form as `.full` (metadata-driven, per-country postal label and rule); if metadata cannot be loaded it falls back to the system country list and a non-empty postal code". Replace "The SDK never blocks a submit because an address is missing" with: a new-card submit is blocked when the postal code violates the country's `required` / `pattern`; other address fields never block; saved-card and wallet paths are not gated; host-provided addresses are not validated. Document `failureReason` → `CheckoutError.message` and that the sheet loads the session once per presentation.
- [ ] **Step 2: checklist.** Add: pattern/required now enforced (verify real patterns for US, CA, GB, CN on dev); fallback config is local; `failureReason` text language follows `Accept-Language` (verify); no session-expiry re-check between attempts in one presentation.
- [ ] **Step 3: Final verification (evidence before claims):** `swift test` (0 failures); full simulator suite (0 failures); Demo build succeeds; manual dev run: (a) declining card keeps the sheet open and shows the reason, (b) simple form: change country US→CA and confirm the postal label/error follows, (c) invalid postal blocks Pay, valid one pays, (d) airplane mode before opening the sheet is NOT testable (session load needs the network), so test metadata failure by pointing the Demo at an environment whose `/api/address/country` fails if available; otherwise report (d) as covered by unit tests only.
- [ ] **Step 4: Report** the results per criterion to the user, listing anything unverified. Do not commit unless asked.
