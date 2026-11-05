# COF Saved-Card Home Collapse + "View more" Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** On the PaymentSheet home page, show a single pre-selected saved card with a "View more" affordance (only when 2+ cards), and open the full saved-card list on a dedicated in-sheet page where picking a card selects it and returns home; selection is shown by a theme-color border highlight with no radio indicator.

**Architecture:** Pure Content-layer change in `CheckoutContentViewController`. A third in-sheet page (`allSavedCardsStack`) is added alongside `homeStack`/`newCardStack`, navigated with the existing `PageTransition` / `performPageSwitch` / `performHeaderSwitch` pattern (no new infrastructure, no container/Core/delegate/backend change). The full-list page reuses `SavedCardListView`; the home page shows a collapsed summary built from `SavedCardRow`. `SavedCardRow` drops its radio and shows selection only via border highlight. `selectedSavedCardId` + `refreshConfirmButtonState()` stay the single source of truth for selection and Pay enablement.

**Tech Stack:** Swift, UIKit (iOS-only views under `#if canImport(UIKit)`), XCTest. SPM package; `swift test` runs on the macOS host.

**Spec:** `docs/superpowers/specs/2026-11-05-cof-collapsed-saved-card-design.md`

## Global Constraints

- English only in code and docs; identifiers, comments, doc comments, test names, literals all English (AGENTS.md §2).
- New user-facing copy goes through the i18n subsystem in both `en.lproj` and `zh-Hans.lproj` `Localizable.strings` (AGENTS.md §2, product-spec §9).
- Core is UI-agnostic; Content layer imports no container/controller/PassKit types; dependency is one-way `Container → Content → Theme`. No new delegate method, no container change.
- iOS-only views stay gated by `#if canImport(UIKit)`; `swift test` (host, no UIKit) must pass.
- Sensitive-data boundary unchanged: rows are presentational over `SavedCard` (brand/last4/expiry) only.
- Selecting a saved card never submits; the user taps Pay to submit (payment truth unchanged).
- Do not add tests beyond what is asked; when changing tested logic, update its tests (AGENTS.md §4).

## Review Focus

- **Exactly one saved card:** no "View more" shown, the single card is pre-selected, Pay enabled. (Task 3)
- **Entering New card then returning home:** the first card is re-selected (not left blank) so Pay reflects a valid default. (Task 3)
- **Picking a non-first card on the full list:** home summary updates to show the picked card, and it stays selected after return. (Task 4)
- **Zero saved cards:** no saved-card section at all; home shows express + "New card" only (unchanged). (Task 3)
- **Selected-state visual:** selected row/summary shows theme-color border highlight and no radio glyph; unselected shows neutral border. (Task 1)

---

### Task 1: Remove the radio from `SavedCardRow`; selection = border highlight only

**Files:**
- Modify: `Sources/SunbayCheckout/UI/Content/Components/SavedCardRow.swift`
- Test: `Tests/SunbayCheckoutTests/UI/` (update existing row/selection assertions if any reference a radio; see below)

**Interfaces:**
- Consumes: `ResolvedAppearance`, `SavedCard` (unchanged).
- Produces: `SavedCardRow` with the same public surface (`init(appearance:card:)`, `paymentMethodId`, `onTap`, `setSelected(_:)`) but no `radioView`. `setSelected(_:)` toggles only the border (selected → `appearance.primary`, thicker; unselected → `appearance.border`).

- [ ] **Step 1: Remove `radioView`**

Delete the `radioView` property, its configuration in `configureSubviews`, its arranged-subview slot in the horizontal stack, and its width/height constraints. The stack becomes `[brandBadge, numberLabel, expiryLabel]` (keep the trailing expiry hugging so the row still reads left-to-right).

- [ ] **Step 2: Reduce `setSelected(_:)` to border-only**

`setSelected(_:)` stores `isSelectedRow` and calls `refreshBorder()` only (drop the radio image/tint lines). `refreshBorder()` is unchanged (already border + width driven by `isSelectedRow`).

- [ ] **Step 3: Build and run existing tests to find radio references**

Run: `swift test`
Expected: PASS, OR a compile/assertion failure only where a test referenced the removed radio. Fix those tests minimally (assert on selection via `highlightedSavedCardIdForTest`, not a radio glyph). Do not add new tests here.

- [ ] **Step 4: Commit**

```bash
git add Sources/SunbayCheckout/UI/Content/Components/SavedCardRow.swift
git commit -m "feat(cof): drop radio from SavedCardRow; selection is border-only"
```

---

### Task 2: Add the "View more" i18n copy

**Files:**
- Modify: `Sources/SunbayCheckout/Resources/Localizations/en.lproj/Localizable.strings`
- Modify: `Sources/SunbayCheckout/Resources/Localizations/zh-Hans.lproj/Localizable.strings`

**Interfaces:**
- Produces: localization key `sunbay.cof.viewMore`. (The full-list page title reuses the existing `sunbay.sheet.savedCards` = "Saved cards" / "已保存的卡" — no new title key.)

- [ ] **Step 1: Add the key to both strings files**

en: `"sunbay.cof.viewMore" = "View more";`
zh-Hans: `"sunbay.cof.viewMore" = "查看更多";`

- [ ] **Step 2: Build**

Run: `swift build`
Expected: PASS.

- [ ] **Step 3: Commit**

```bash
git add Sources/SunbayCheckout/Resources/Localizations/en.lproj/Localizable.strings Sources/SunbayCheckout/Resources/Localizations/zh-Hans.lproj/Localizable.strings
git commit -m "feat(cof): add sunbay.cof.viewMore copy (en, zh-Hans)"
```

---

### Task 3: Collapse the home saved-card section to one pre-selected card + "View more"

**Files:**
- Modify: `Sources/SunbayCheckout/UI/Content/CheckoutContentViewController.swift`
- Test: `Tests/SunbayCheckoutTests/UI/CheckoutContentViewControllerTests.swift`

**Interfaces:**
- Consumes: `SavedCardRow` (Task 1), `sunbay.cof.viewMore` (Task 2), existing `savedCards`, `selectedSavedCardId`, `refreshConfirmButtonState()`, `homeStack`, `makeSavedCardList()`.
- Produces:
  - `buildHomeStack()` adds a **home saved-card summary view** (not the full `SavedCardListView`) when `savedCards` is non-empty: a single `SavedCardRow` for the currently selected card, plus — only when `savedCards.count > 1` — a trailing "View more" affordance (label from `sunbay.cof.viewMore` + `chevron.right`, styled like the "New card" entry chevron) that calls `showAllSavedCards()` (Task 4).
  - A stored reference to the summary (e.g. `savedCardSummary`) so it can be rebuilt to reflect the selected card after a pick/return.
  - Default selection: on first build with `savedCards` non-empty, `selectedSavedCardId = savedCards.first?.id` and the summary shows that card selected (border highlight). `showHome()`/returning from new-card re-applies `selectedSavedCardId = savedCards.first?.id` (instead of leaving it nil) when a saved card exists.
  - New DEBUG test seam `isViewMoreVisibleForTest: Bool` (the "View more" affordance exists and is visible).
  - `homeOrderForTest` continues to report `"savedCards"` for the summary slot.

- [ ] **Step 1: Write failing tests**

Add to `CheckoutContentViewControllerTests` (reuse `sampleSavedCards()` = pm_1 visa 4242, pm_2 mastercard 5454):

```swift
// Home pre-selects the first saved card: Pay is visible+enabled immediately, nothing submitted.
func test_home_preSelectsFirstSavedCard_payEnabled_noSubmit() {
    let vc = makeVC(savedCards: sampleSavedCards())
    vc.loadViewIfNeeded()
    let delegate = MockContentDelegate()
    vc.delegate = delegate
    XCTAssertEqual(vc.highlightedSavedCardIdForTest, "pm_1")
    XCTAssertTrue(vc.isConfirmButtonVisibleForTest)
    XCTAssertTrue(vc.isConfirmButtonEnabledForTest)
    XCTAssertNil(delegate.lastRequestedAction)
}

// "View more" shows only with 2+ saved cards.
func test_viewMore_visibleOnlyForMultipleCards() {
    let one = makeVC(savedCards: [sampleSavedCards()[0]])
    one.loadViewIfNeeded()
    XCTAssertFalse(one.isViewMoreVisibleForTest)
    XCTAssertEqual(one.highlightedSavedCardIdForTest, "pm_1")

    let many = makeVC(savedCards: sampleSavedCards())
    many.loadViewIfNeeded()
    XCTAssertTrue(many.isViewMoreVisibleForTest)
}

// New card then back re-selects the first card (Pay stays valid), not blank.
func test_homeToNewCardAndBack_reselectsFirstCard() {
    let vc = makeVC(savedCards: sampleSavedCards())
    vc.loadViewIfNeeded()
    vc.tapNewCardEntryForTest()
    vc.tapBackForTest()
    XCTAssertTrue(vc.isHomeVisibleForTest)
    XCTAssertEqual(vc.highlightedSavedCardIdForTest, "pm_1")
    XCTAssertTrue(vc.isConfirmButtonVisibleForTest)
}
```

Update the two existing tests whose premise changes: delete/replace `test_payButtonHiddenWhenNothingSelectedOnSavedList` (home now pre-selects, so Pay is shown — assert the pre-selected behavior instead) and update `test_homeToNewCardAndBack_clearsHighlight_andHidesPay` to the re-select behavior above. Leave `test_selectingSavedCardDoesNotSubmit_payTapSubmits`, `test_realRowTap_highlightsAndEnablesPay_withoutSubmitting`, and `PaymentSheetRunCheckoutTests.payWithSavedCard` working (they select pm_1/pm_2 explicitly and must still submit the chosen id).

- [ ] **Step 2: Run tests to verify they fail**

Run: `swift test --filter CheckoutContentViewControllerTests`
Expected: FAIL (new seam `isViewMoreVisibleForTest` undefined; pre-selection assertions fail).

- [ ] **Step 3: Implement the home summary + default selection**

In `buildHomeStack()`, replace the `makeSavedCardList()` branch with a `makeSavedCardSummary()` that returns the single-card summary + conditional "View more". Set the default `selectedSavedCardId = savedCards.first?.id` where the home is first assembled and in `showHome()` when `!savedCards.isEmpty`. Keep `refreshConfirmButtonState()` as the enabler. Add the `isViewMoreVisibleForTest` DEBUG seam. The "View more" tap calls `showAllSavedCards()` (defined in Task 4; stub it to no-op if implementing strictly in order, then wire in Task 4).

- [ ] **Step 4: Run tests to verify they pass**

Run: `swift test --filter CheckoutContentViewControllerTests`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add Sources/SunbayCheckout/UI/Content/CheckoutContentViewController.swift Tests/SunbayCheckoutTests/UI/CheckoutContentViewControllerTests.swift
git commit -m "feat(cof): collapse home to one pre-selected saved card + View more"
```

---

### Task 4: Full saved-card list page ("View more") with pick-and-return

**Files:**
- Modify: `Sources/SunbayCheckout/UI/Content/CheckoutContentViewController.swift`
- Test: `Tests/SunbayCheckoutTests/UI/CheckoutContentViewControllerTests.swift`

**Interfaces:**
- Consumes: `makeSavedCardList()` (reuses `SavedCardListView`), `PageTransition` via `performPageSwitch(direction:animated:change:)`, `performHeaderSwitch`, `reportContentHeightIfChanged()`, `sunbay.sheet.savedCards` title, `selectedSavedCardId`, `refreshConfirmButtonState()`, the home summary from Task 3.
- Produces:
  - `allSavedCardsStack: UIStackView` added as a third sibling in `assembleRootStack()` (hidden by default).
  - `showAllSavedCards()` — forward page switch: hides `homeStack`, shows `allSavedCardsStack` (built lazily with the full `SavedCardListView`, its `selectedPaymentMethodId` set to `selectedSavedCardId`), header title → `sunbay.sheet.savedCards`, back button visible (back returns to home via existing `showHome()` logic, which also re-applies the home summary).
  - The full list's `onSelect` sets `selectedSavedCardId`, rebuilds the home summary to that card, `refreshConfirmButtonState()`, and calls `showHome()` (auto-return / picker flow).
  - DEBUG seams: `isAllSavedCardsVisibleForTest: Bool`, `tapViewMoreForTest()`, `tapFullListRowForTest(_:)`.

- [ ] **Step 1: Write failing tests**

```swift
// View more opens the full list page; back returns home with selection intact.
func test_viewMore_opensFullList_backReturnsHome() {
    let vc = makeVC(savedCards: sampleSavedCards())
    vc.loadViewIfNeeded()
    vc.tapViewMoreForTest()
    XCTAssertTrue(vc.isAllSavedCardsVisibleForTest)
    XCTAssertFalse(vc.isHomeVisibleForTest)
    vc.tapBackForTest()
    XCTAssertTrue(vc.isHomeVisibleForTest)
    XCTAssertEqual(vc.highlightedSavedCardIdForTest, "pm_1")
}

// Picking a non-first card on the full list selects it and auto-returns home showing that card.
func test_fullList_pickSelectsAndReturnsHome() {
    let vc = makeVC(savedCards: sampleSavedCards())
    vc.loadViewIfNeeded()
    let delegate = MockContentDelegate()
    vc.delegate = delegate
    vc.tapViewMoreForTest()
    vc.tapFullListRowForTest("pm_2")
    XCTAssertTrue(vc.isHomeVisibleForTest, "Picking a card returns to home.")
    XCTAssertEqual(vc.highlightedSavedCardIdForTest, "pm_2")
    XCTAssertTrue(vc.isConfirmButtonVisibleForTest)
    XCTAssertNil(delegate.lastRequestedAction, "Picking must not submit.")

    vc.simulateTapPay()
    guard case let .confirmSavedCard(id) = delegate.lastRequestedAction else {
        return XCTFail("Expected .confirmSavedCard")
    }
    XCTAssertEqual(id, "pm_2")
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `swift test --filter CheckoutContentViewControllerTests`
Expected: FAIL (seams/page undefined).

- [ ] **Step 3: Implement the third page + navigation**

Add `allSavedCardsStack` in `assembleRootStack()` (hidden). Implement `showAllSavedCards()` and the full-list `onSelect` (select + rebuild summary + `showHome()`), routing both page switches through `performPageSwitch(direction:)` and header through `performHeaderSwitch`, and calling `reportContentHeightIfChanged()` after — mirroring `showNewCardSubpage`/`showHome`. Ensure `showHome()` restores the home title/back-hidden and re-applies the home summary for the current `selectedSavedCardId`. Add the DEBUG seams (`tapFullListRowForTest` taps the full list's `tapRowForTest`). Respect the processing lock (`isLockedAgainstNewConfirm`) exactly as the other page switches do.

- [ ] **Step 4: Run the full suite**

Run: `swift test`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add Sources/SunbayCheckout/UI/Content/CheckoutContentViewController.swift Tests/SunbayCheckoutTests/UI/CheckoutContentViewControllerTests.swift
git commit -m "feat(cof): add full saved-card list page with pick-and-return"
```

---

### Task 5: Demo + full-suite verification

**Files:**
- Modify (if needed): `Example/SunbayCheckoutDemo/Sources/` only if a demo fixture hard-codes the old all-cards home layout.

**Interfaces:**
- Consumes: everything above. No new public API.

- [ ] **Step 1: Run the whole test suite**

Run: `swift test`
Expected: PASS (state machine, selection, navigation, e2e targets unaffected).

- [ ] **Step 2: Build the package**

Run: `swift build`
Expected: PASS, no warnings introduced by this change.

- [ ] **Step 3: Sanity-check the demo**

Grep `Example/SunbayCheckoutDemo/Sources/` for any assertion/snapshot of the saved-card home that assumed all cards render; update copy/fixtures only if present. The demo calls only public API (AGENTS.md §5) — no internal-type coupling.

- [ ] **Step 4: Commit (only if demo changed)**

```bash
git add Example/SunbayCheckoutDemo/Sources
git commit -m "chore(demo): align demo with collapsed saved-card home"
```
