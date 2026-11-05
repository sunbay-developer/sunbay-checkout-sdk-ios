# Design: Floating-label text fields + contextual close button

Date: 2026-11-05
Status: Proposed (awaiting approval)
Scope: Small-to-medium UI change, Content/Container layer only. No public API change.

## Intent and why

Two UI refinements to the checkout sheet, driven by a real-device screenshot review:

1. **The close (✕) button should appear only on the home page**, not on the
   sub-pages ("Add card" and the full saved-card list). Sub-pages already show a
   back (‹) button; today they also show ✕, giving two competing dismissal
   affordances on a sub-page. The ✕ belongs to the root only.

2. **Text inputs should use a floating (focus) label** instead of a plain
   placeholder. Today the field label is `UITextField.placeholder`, which
   disappears the instant the user types, so a field with content shows no label.
   A Stripe/Material-style floating label keeps the label visible — it shrinks and
   rises to the top of the field when the field is focused or non-empty — so the
   user always knows what each filled field is.

## Goals

- ✕ visible on home, hidden on the "Add card" and "View more saved cards"
  sub-pages during normal navigation.
- Every **text** input (card number, MM/YY, CVC, address line, postal/ZIP, and the
  dynamic address text fields) shows a floating label that animates on focus and
  reflects "has content" state.
- Keep the existing focus-border highlight, error styling, PCI keyboard hardening,
  and display formatting unchanged.

## Non-goals / anti-goals

- No change to the country selector (it is a `UIButton` menu, not a text field);
  floating labels apply to text fields only. It keeps its current inline title.
- No public API change; no new theme tokens unless strictly required.
- Do not alter encryption, validation, logging, or persistence. The new field is
  pure presentation — it must not log or persist any card data (security-and-pci.md §4).
- Do not trap the user: the ✕ must remain reachable in the locked `reconciling`
  recovery state even on a sub-page (see Constraints).

## Constraints

- iOS 15 minimum; UIKit only (Content layer is UIKit, Core stays UI-agnostic).
- English-only in code/docs (AGENTS.md §2).
- `reconciling` edge case: `enterReconciling()` re-enables ✕ as the *only* way to
  leave the sheet while locked, and a payment can be confirmed from the "Add card"
  sub-page. Hiding ✕ on sub-pages unconditionally would trap such a user (back is
  disabled while locked). Therefore ✕ visibility is driven by *navigation*, and
  `enterReconciling()` explicitly re-shows ✕ regardless of the current page.

## Approaches considered

**Part 2 (floating label) — the larger piece:**

- **A — Reusable `FloatingLabelTextField` (a `UITextField` subclass). CHOSEN.**
  One component owns its floating `UILabel`, the float/un-float animation, and
  overrides `textRect/editingRect/placeholderRect` to reserve top space for the
  label. Card fields and address text fields swap their bare `UITextField` for it.
  Cohesive, one place to tune animation, minimal integration churn, matches the
  "small, stable component" goal.
- B — Per-field wrapper view (label stacked over field) in both `CardFormView`
  and `FieldContainerView`. Rejected: the card group's fixed row height gets
  cramped with label-over-field, and there are two integration points to keep in
  sync.
- C — Inline label animation duplicated inside each existing view. Rejected:
  duplicates the float logic in two places and bloats `CardFormView`.

**Part 1 (close button):** the header already expresses home-vs-subpage via
`setBackVisible(false/true)` inside the three navigation methods. Add a mirroring
`setCloseVisible(_:)` and call it from the same three places. No alternative worth
listing — this is the one sensible way given the existing structure.

## The design

### Part 1 — Contextual close button

- `SheetHeaderView`: add `func setCloseVisible(_ visible: Bool)` that sets
  `closeButton.isHidden = !visible`. This is independent of the existing
  `setCloseEnabled(_:)` (enabled/dimmed state) so the two do not collide. The title
  is center-pinned with `>=`/`<=` relations to both buttons, so hiding ✕ keeps the
  title centered.
- `CheckoutContentViewController`:
  - `showHome(...)` → inside its `performHeaderSwitch` closure, add
    `self.header.setCloseVisible(true)`.
  - `showNewCardSubpage(...)` → add `self.header.setCloseVisible(false)`.
  - `showAllSavedCards()` → add `self.header.setCloseVisible(false)`.
  - `enterReconciling()` → add `header.setCloseVisible(true)` so the locked
    recovery state always exposes ✕ even if entered from a sub-page.

### Part 2 — `FloatingLabelTextField`

New file `Sources/SunbayCheckout/UI/Content/Components/FloatingLabelTextField.swift`,
iOS-only (`#if canImport(UIKit)`), a `final class FloatingLabelTextField: UITextField`.

- Owns a `floatingLabel: UILabel`. The field's title is set via a `title` property
  (replacing the old `placeholder` usage); the real `placeholder` stays empty so
  there is no double text.
- **State:** the label "floats" (small font, raised to the top inset) when the
  field is first responder OR its text is non-empty; otherwise it "rests" (resting
  font/color, vertically centered with the text baseline, i.e. where a placeholder
  would sit).
- **Animation:** `editingDidBegin` / `editingDidEnd` / `editingChanged` drive a
  short `UIView.animate` (≈0.15s) transform+color update. Respects
  `appearance.pageTransitionsEnabled` for the animated-vs-instant choice (reuse the
  existing appearance signal so motion settings stay consistent); falls back to an
  instant update when animations are off.
- **Insets:** override `textRect(forBounds:)`, `editingRect(forBounds:)`, and
  `placeholderRect(forBounds:)` to reserve a top band for the floated label so the
  text does not overlap it.
- **Colors/fonts:** resting label = `appearance.textSecondary`; floated label =
  `appearance.primary` while focused, else `appearance.textSecondary`; error state
  (when driven by the owner) = `appearance.danger`. Text font/color unchanged
  (`appearance.cardFieldFont`, `appearance.text`). The floated font is a smaller
  derived size.
- Constructed with `(appearance:)`; a `title` setter. No knowledge of card vs
  address semantics.

### Integration

- `CardFormView`: replace `panField/expiryField/cvvField` (`UITextField`) with
  `FloatingLabelTextField`, set `.title` instead of `.placeholder`. Keep all other
  wiring (security, formatting, delegate, targets, group border focus logic).
  Bump the per-field row height so label + text fit (compact 48 / regular 56; today
  44 / 52) — verified against the group's top/bottom anchors and the two dividers.
- `SimpleAddressFormView`: `line1Field`, `postalField` become
  `FloatingLabelTextField` with `.title`. `countryButton` (menu) unchanged.
- `DynamicAddressFormView.makeField(_:)`: the text-field branch builds a
  `FloatingLabelTextField` with the field's title. The state-menu and country-menu
  branches unchanged.
- `FieldContainerView` keeps wrapping the control; it still flips its border on
  focus. Its height floor (`>= 48`) accommodates the floated label.

## What is left to the builder

- Exact floated font size / vertical offsets / animation duration within the
  stated ranges — tune for visual parity with the screenshot.
- Whether to derive the floated font from `cardFieldFont` or a fixed caption size —
  builder's call, must stay legible at iOS 15 default Dynamic Type.
- Any minor constraint adjustments inside `CardFormView`'s group needed to seat the
  taller rows cleanly.

## Verification

- `swift test` on the host (state machine / encryption / recovery tests are
  UI-agnostic and must stay green; UIKit views are `#if canImport(UIKit)`-gated).
- Build the SDK target.
- Visual check in `Example/SunbayCheckoutDemo` on device/simulator: label floats on
  focus and stays floated with content; ✕ shows on home only and reappears in the
  reconciling state; no overlap, correct colors in light/dark.
