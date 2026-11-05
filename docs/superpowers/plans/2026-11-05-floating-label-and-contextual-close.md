# Floating-label text fields + contextual close button — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Show the sheet's close (✕) button only on the home page, and give every text input a floating focus-label that stays visible when the field has content.

**Architecture:** Part 1 adds a `setCloseVisible(_:)` toggle to `SheetHeaderView` and calls it from the three navigation methods in `CheckoutContentViewController` (plus the reconciling recovery path). Part 2 adds a reusable `FloatingLabelTextField` (`UITextField` subclass) that owns a floating label and animates it on focus/content, then swaps it in for the bare `UITextField`s in the card form and address forms.

**Tech Stack:** Swift, UIKit (Content layer, iOS 15+), XCTest.

**Spec:** `docs/superpowers/specs/2026-11-05-floating-label-and-contextual-close-design.md`

## Global Constraints

- Swift only; UIKit for the Content layer; iOS 15 minimum. (AGENTS.md §2)
- English only in all code and docs — comments, identifiers, strings, test names. (AGENTS.md §2)
- No public API change; internal types must not leak across the public boundary. (AGENTS.md §2)
- The new field is pure presentation: it must never log or persist card data, and must not touch encryption/validation. (AGENTS.md §2.3/2.4, security-and-pci.md §4)
- Core stays UI-agnostic; all UIKit code is gated by `#if canImport(UIKit)`. (AGENTS.md §2.6)
- UIKit views do not compile on the macOS host, so `#if canImport(UIKit)` XCTest files are vacuous under `swift test` (must still compile/pass green = vacuous) and only truly exercise under the iOS Simulator SDK — this matches the existing UI test suites. Do not add host-runnable tests for UIKit-only behavior.
- Do not add tests beyond what is asked; when changing tested logic, update its tests. (AGENTS.md §4)
- Stage specific files by name; do not commit/push unless the user asks. (AGENTS.md §5)

## Review Focus

- **Reconciling entered from the "Add card" sub-page:** ✕ hidden on sub-pages must be re-shown in `enterReconciling()`, else the user is trapped (back is disabled while locked). → Task 2 test `testReconcilingShowsCloseEvenOnSubpage`.
- **A field pre-filled before first focus** (e.g. test seam / programmatic text): the label must start floated, not resting over the text. → Task 3 test `testLabelFloatsWhenNonEmptyWithoutFocus`.
- **Animations disabled** (`appearance.pageTransitionsEnabled == false`): float state must still apply instantly, with no stuck mid-transform. → Task 3 test `testFloatAppliesInstantlyWhenAnimationsDisabled`.
- **Error color precedence on a floated label:** when the owner marks the field in error, the floated label color must reflect danger over focus/primary. → Task 3 test `testErrorColorOverridesFocusColor`.
- **Text never overlaps the floated label:** `textRect/editingRect` must reserve the top band. → Task 3 test `testTextRectReservesTopBandForLabel`.

---

## Task 1: `setCloseVisible(_:)` on the header

**Files:**
- Modify: `Sources/SunbayCheckout/UI/Content/Components/SheetHeaderView.swift`
- Test: `Tests/SunbayCheckoutTests/UI/` (existing header/content UI test file; `#if canImport(UIKit)`)

**Interfaces:**
- Produces: `func setCloseVisible(_ visible: Bool)` on `SheetHeaderView` (sets `closeButton.isHidden = !visible`); `#if DEBUG var isCloseVisibleForTest: Bool { !closeButton.isHidden }`.

- [ ] **Step 1: Implement `setCloseVisible(_ visible: Bool)`** in `SheetHeaderView`, next to `setBackVisible(_:)`. Body: `closeButton.isHidden = !visible`. Independent of `setCloseEnabled(_:)`. Add a doc comment (English) noting it is visibility only, orthogonal to enabled state.
- [ ] **Step 2: Add `#if DEBUG` test readout** `var isCloseVisibleForTest: Bool { !closeButton.isHidden }` alongside the existing `isCloseEnabledForTest`.
- [ ] **Step 3: Verify it builds** — Run: `swift build`. Expected: success. The header is UIKit-gated so this change is not compiled on the host; `swift build` confirms no host break, and the iOS build in Task 5 confirms the real compile.
- [ ] **Step 4: Commit** — `git add Sources/SunbayCheckout/UI/Content/Components/SheetHeaderView.swift && git commit -m "feat(ui): add setCloseVisible to SheetHeaderView"`.

## Task 2: Contextual close visibility in navigation

**Files:**
- Modify: `Sources/SunbayCheckout/UI/Content/CheckoutContentViewController.swift`
- Test: `Tests/SunbayCheckoutTests/UI/CheckoutContentViewControllerTests.swift` (`#if canImport(UIKit)`)

**Interfaces:**
- Consumes: `SheetHeaderView.setCloseVisible(_:)`, `isCloseVisibleForTest` (Task 1).
- Produces: `#if DEBUG var isCloseVisibleForTest: Bool` on `CheckoutContentViewController` forwarding `header.isCloseVisibleForTest`, for the UI tests.

- [ ] **Step 1: Wire close visibility into the three navigation methods.** In `showHome(...)`'s `performHeaderSwitch` closure add `self.header.setCloseVisible(true)`; in `showNewCardSubpage(...)` add `self.header.setCloseVisible(false)`; in `showAllSavedCards()` add `self.header.setCloseVisible(false)`.
- [ ] **Step 2: Keep ✕ reachable while reconciling.** In `enterReconciling()` add `header.setCloseVisible(true)` after the existing `header.setCloseEnabled(true)`.
- [ ] **Step 3: Add the `#if DEBUG` forwarding readout** `var isCloseVisibleForTest: Bool { header.isCloseVisibleForTest }` on the content VC (near the other `*ForTest` seams).
- [ ] **Step 4: Write the failing UI tests** (`#if canImport(UIKit)`, vacuous on host). Follow the existing test style in `CheckoutContentViewControllerTests.swift`:

```swift
func testCloseVisibleOnHomeHiddenOnNewCardSubpage() {
    let vc = makeVC(savedCards: [])
    vc.loadViewIfNeeded()
    XCTAssertTrue(vc.isCloseVisibleForTest)   // home
    vc.openNewCardForTest()
    XCTAssertFalse(vc.isCloseVisibleForTest)  // sub-page
}

func testReconcilingShowsCloseEvenOnSubpage() {
    let vc = makeVC(savedCards: [])
    vc.loadViewIfNeeded()
    vc.openNewCardForTest()
    vc.fillCardForTest()
    // drive a confirm into the reconciling (pending/unknown) recovery state via the existing seam
    vc.enterReconcilingForTest()
    XCTAssertTrue(vc.isCloseVisibleForTest)
}
```

If no `enterReconcilingForTest()` seam exists, add a minimal `#if DEBUG` seam that calls `enterReconciling()` (mirroring the existing `*ForTest` seams), or drive it through the already-present state-machine seam used by `PaymentSheetRunCheckoutTests`. Prefer the existing path; add a seam only if none reaches `enterReconciling()`.
- [ ] **Step 5: Verify (host)** — Run: `swift test`. Expected: PASS (UIKit tests vacuous on host; nothing regresses).
- [ ] **Step 6: Commit** — `git add Sources/SunbayCheckout/UI/Content/CheckoutContentViewController.swift Tests/SunbayCheckoutTests/UI/CheckoutContentViewControllerTests.swift && git commit -m "feat(ui): show close button only on home page"`.

## Task 3: `FloatingLabelTextField`

**Files:**
- Create: `Sources/SunbayCheckout/UI/Content/Components/FloatingLabelTextField.swift`
- Test: `Tests/SunbayCheckoutTests/UI/FloatingLabelTextFieldTests.swift` (`#if canImport(UIKit)`)

**Interfaces:**
- Consumes: `ResolvedAppearance` (`.text`, `.textSecondary`, `.primary`, `.danger`, `.cardFieldFont`, `.cornerRadius`, `.pageTransitionsEnabled`).
- Produces:
  - `init(appearance: ResolvedAppearance)`
  - `var title: String? { get set }` — sets the floating label text (replaces `placeholder` usage).
  - `func setErrorActive(_ active: Bool)` — owner-driven error color override.
  - `#if DEBUG` readouts: `var isLabelFloatedForTest: Bool`, `var floatingLabelColorForTest: UIColor`.

- [ ] **Step 1: Write the failing tests** (`#if canImport(UIKit)`), covering the Review-Focus items:

```swift
func testLabelFloatsWhenNonEmptyWithoutFocus() {
    let f = FloatingLabelTextField(appearance: .preview)
    f.title = "ZIP"
    f.text = "94107"
    f.layoutIfNeeded()
    XCTAssertTrue(f.isLabelFloatedForTest)
}

func testFloatAppliesInstantlyWhenAnimationsDisabled() {
    let f = FloatingLabelTextField(appearance: .previewNoMotion) // pageTransitionsEnabled == false
    f.title = "CVC"
    f.becomeFirstResponder()
    XCTAssertTrue(f.isLabelFloatedForTest) // no pending animation
}

func testErrorColorOverridesFocusColor() {
    let f = FloatingLabelTextField(appearance: .preview)
    f.title = "Card number"
    f.becomeFirstResponder()
    f.setErrorActive(true)
    XCTAssertEqual(f.floatingLabelColorForTest, ResolvedAppearance.preview.danger)
}

func testTextRectReservesTopBandForLabel() {
    let f = FloatingLabelTextField(appearance: .preview)
    f.title = "MM / YY"
    f.frame = CGRect(x: 0, y: 0, width: 200, height: 52)
    let rect = f.textRect(forBounds: f.bounds)
    XCTAssertGreaterThan(rect.minY, 0) // top band reserved
}
```

Use the existing appearance preview helper the other UI tests use (`.preview`); add a no-motion variant only if one does not already exist.
- [ ] **Step 2: Run tests to verify they fail** — Run: `swift test`. Expected: on host these are vacuous (type missing → compile error in the test only when UIKit present). Under host they simply do not run; confirm `swift test` still passes for the rest. The real RED is in the iOS Simulator build.
- [ ] **Step 3: Implement `FloatingLabelTextField`.** `final class FloatingLabelTextField: UITextField`, `#if canImport(UIKit)`. Owns `private let floatingLabel = UILabel()`. Rules:
  - Floated when `isFirstResponder || !(text ?? "").isEmpty`; else resting.
  - `editingDidBegin`/`editingDidEnd`/`editingChanged` targets recompute and animate (≈0.15s) via `UIView.animate`; when `appearance.pageTransitionsEnabled == false`, apply the transform/color without animation.
  - Override `textRect(forBounds:)`, `editingRect(forBounds:)`, `placeholderRect(forBounds:)` to reserve a top band equal to the floated label height.
  - Label color: `setErrorActive(true)` → `danger`; else floated+focused → `primary`; else → `textSecondary`. Text uses `cardFieldFont`/`text`.
  - `title` sets `floatingLabel.text` and leaves `placeholder` empty.
  - Floated font = a smaller size derived from `cardFieldFont` (legible at default Dynamic Type).
  - No logging/persistence of any kind.
- [ ] **Step 4: Verify (host)** — Run: `swift test`. Expected: PASS (host green; UIKit tests vacuous).
- [ ] **Step 5: Commit** — `git add Sources/SunbayCheckout/UI/Content/Components/FloatingLabelTextField.swift Tests/SunbayCheckoutTests/UI/FloatingLabelTextFieldTests.swift && git commit -m "feat(ui): add FloatingLabelTextField component"`.

## Task 4: Adopt `FloatingLabelTextField` in the forms

**Files:**
- Modify: `Sources/SunbayCheckout/UI/Content/Components/CardFormView.swift`
- Modify: `Sources/SunbayCheckout/UI/Content/Components/SimpleAddressFormView.swift`
- Modify: `Sources/SunbayCheckout/UI/Content/Components/DynamicAddressFormView.swift`

**Interfaces:**
- Consumes: `FloatingLabelTextField(appearance:)`, `.title`, `.setErrorActive(_:)` (Task 3).

- [ ] **Step 1: `CardFormView`** — change `panField`/`expiryField`/`cvvField` from `UITextField` to `FloatingLabelTextField(appearance:)`. Replace the three `.placeholder = localize(...)` with `.title = localize(...)`. Keep `CardFieldSecurity.apply`, the `delegate`, the `editingChanged/DidBegin/DidEnd` targets, formatting, and `refreshGroupBorder()` unchanged. Route `showFieldError(_:message:)` to call `setErrorActive(true/false)` on the relevant field(s) in addition to the group border. Bump `rowHeight` to `compact 48 / regular 56` and confirm the group's top/bottom anchors and the two dividers still seat cleanly.
- [ ] **Step 2: `SimpleAddressFormView`** — `line1Field`/`postalField` become `FloatingLabelTextField(appearance:)`; `.placeholder = localize(...)` → `.title = localize(...)`. `countryButton` (menu) unchanged.
- [ ] **Step 3: `DynamicAddressFormView.makeField(_:)`** — the plain text-field branch builds `FloatingLabelTextField(appearance:)` with `.title = field.placeholder`. State-menu / country-menu branches unchanged. Ensure the value-preservation flow (`reload(locale:)` re-applying entered values) still works — values are re-applied to the fresh `FloatingLabelTextField`s exactly as before.
- [ ] **Step 4: Verify (host)** — Run: `swift test`. Expected: PASS, including `DynamicAddressFormViewTests` value-preservation (vacuous on host; must not break compilation of the shared code paths).
- [ ] **Step 5: Commit** — `git add Sources/SunbayCheckout/UI/Content/Components/CardFormView.swift Sources/SunbayCheckout/UI/Content/Components/SimpleAddressFormView.swift Sources/SunbayCheckout/UI/Content/Components/DynamicAddressFormView.swift && git commit -m "feat(ui): adopt floating labels across card and address fields"`.

## Task 5: iOS build + visual verification

**Files:** none (verification only).

- [ ] **Step 1: Build for the iOS Simulator SDK** so the `#if canImport(UIKit)` code and tests actually compile and the Task 2/3 tests run RED→GREEN. Use the project's existing simulator build/test invocation (xcodebuild or the demo scheme in `Example/SunbayCheckoutDemo`). Expected: build succeeds; new UI tests pass.
- [ ] **Step 2: Visual check in `Example/SunbayCheckoutDemo`** on a simulator/device: label rests as placeholder, floats on focus, stays floated with content; ✕ on home only and reappears in reconciling; no label/text overlap; correct colors in light + dark. Record the result in the final summary (no commit).
