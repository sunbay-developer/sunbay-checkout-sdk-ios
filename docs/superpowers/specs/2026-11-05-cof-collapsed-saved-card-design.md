# COF Saved-Card Home Collapse + "View more" — Design

Date: 2026-11-05
Status: Proposed (awaiting approval)
Scope: Small change (UI, Content layer only)

## Intent and why

On the PaymentSheet home page the saved-card (COF) list currently renders **every**
saved card as a flat radio list. When a customer has several saved cards this
pushes the "New card" entry and the whole sheet far down, and buries the one card
they most likely want.

Goal: on the home page, show a single saved card (a "Saved" summary) with a
trailing **"View more"** affordance, matching the Stripe reference. Tapping
"View more" opens a second in-sheet page listing all saved cards; picking one
returns to the home page with that card shown and selected. This keeps the home
page compact and the primary card one tap from Pay.

## Goals / non-goals / anti-goals

Goals:
- Home page shows exactly one saved-card summary + "View more" when there are 2+ saved cards.
- A dedicated in-sheet "all saved cards" page reachable via "View more".
- Selection effect is border-in-theme-color highlight only (radio indicator removed).
- No change to Core, `CofService`, `CheckoutController`, the delegate boundary, or the backend contract.

Non-goals:
- No pagination of the full list (the "view more" page shows all cards in one scroll).
- No change to how saved cards are fetched or to the `SavedCard` model.
- No new express / new-card behavior.

Anti-goals (would make this a failure even if it "works"):
- Introducing any modal / presented picker or UIKit navigation into the Content layer
  (breaks the host-agnostic, one-way `Container → Content → Theme` design).
- Any new delegate method or container-side change for a pure in-content navigation concern.
- Leaking sensitive data: rows stay presentational (`SavedCard` = brand/last4/expiry only).

## Constraints

- English-only in code/docs; new copy goes through the existing i18n subsystem
  (`Localizable.strings`, en + zh-Hans), per AGENTS.md §2 and product-spec §9.
- Content layer imports no container/controller types; navigation uses the existing
  `PageTransition` page-swap pattern, not pushes/presents.
- Payment truth unchanged: selecting a card never submits; the user still taps Pay.

## Approaches considered

1. **Third in-sheet page, reuse `SavedCardListView` + `PageTransition` (chosen).**
   Add an `allSavedCardsStack` sibling to `homeStack`/`newCardStack`, navigated with the
   existing `performPageSwitch` / `performHeaderSwitch`. The home page shows a single
   collapsed `SavedCardRow` + a "View more" row; the full page reuses the existing
   `SavedCardListView`. Zero new infrastructure; identical to how the new-card subpage works.
   Trade-off: adds one more page-state flag to the VC.

2. **Modal / presented picker VC for the full list.** Rejected — it would require the
   Content layer to own UIKit presentation/navigation, violating the host-agnostic
   boundary and the anti-goal above.

3. **Inline expand/collapse in place (disclosure) on the home page.** Rejected — it
   re-grows the home page to the full list height (the exact problem we are solving) and
   does not match the Stripe reference's dedicated "Saved" summary + drill-in.

Chosen: Approach 1.

## The how (decided)

Four behavior decisions (confirmed with the requester):

1. **Default card = pre-selected.** The home page shows the first saved card and
   auto-selects it, so Pay is immediately enabled (matches the Stripe highlighted card).
   This changes today's "nothing selected until the user taps" rule for the saved-card
   home page specifically.
2. **Pick on the "view more" page = select + auto-return.** Tapping a card on the full
   list selects it and immediately navigates back to the home page (picker flow); the
   home summary then shows that card.
3. **Collapse only when 2+ cards.** With exactly one saved card, show it with no "View
   more". With zero, no saved-card section at all (unchanged). "View more" appears only
   for 2+ cards.
4. **Selection effect = border theme-color highlight only; radio removed.** `SavedCardRow`
   drops the `radioView` entirely. Selected = brand/`appearance.primary` tinted, thicker
   border (as today's selected border); unselected = neutral border. Applies to both the
   home summary row and the full-list rows.

Additional calls I'm making (minor, mine to settle):

- **Copy:** new i18n key `sunbay.cof.viewMore` = "View more" (en) / "查看更多" (zh-Hans),
  rendered as a trailing tappable label + chevron on the home summary, styled like the
  existing "New card" entry's chevron. The existing `sunbay.cof.newPaymentMethod` is reused.
- **"View more" page title:** reuse a saved-cards header; add `sunbay.cof.savedCardsTitle`
  = "Saved cards" / "已存卡" for the second page's header title. (If you'd rather reuse an
  existing title, say so.)
- **Home summary tap target:** tapping the summary card's body does NOT re-open the list
  (it's already the selected card); only the explicit "View more" affordance navigates.
  This keeps one card = one meaning, and avoids an accidental drill-in.
- **Selection sync:** returning from the "view more" page updates the home summary to show
  the chosen card and keeps `selectedSavedCardId` + `refreshConfirmButtonState()` as the
  single source of truth (no new state path).
- **Entering the new-card subpage** still clears the saved-card selection (as today); on
  returning home the pre-selected first card is re-applied so Pay reflects a valid default.

## What's left to the builder

- Exact composition of the home summary row (reuse `SavedCardRow` for the card visual +
  a sibling "View more" control, or a small dedicated summary view) — builder's choice,
  as long as it reuses `SavedCardRow`'s visual and the border-highlight styling.
- Wiring the third page through `performPageSwitch(direction:)` / `performHeaderSwitch`
  and `reportContentHeightIfChanged()` exactly like `showNewCardSubpage`/`showHome`.
- **Update affected tests** (do not add beyond what's needed, per AGENTS.md §4):
  - `SavedCardListView.tapRowForTest` / the VC's `tapSavedCardRowForTest`,
    `highlightedSavedCardIdForTest`, `homeOrderForTest` test seams must keep working or be
    updated to the new structure.
  - `CheckoutContentViewControllerTests`: the "selecting a saved card must not submit" and
    "real row tap highlights + enables Pay" tests, plus any assertion that depended on a
    radio indicator or on all cards being present on the home page, updated for the
    pre-selected-default + collapsed-home behavior.
  - `PaymentSheetRunCheckoutTests.payWithSavedCard` (uses `tapSavedCardRowForTest("pm_1")`)
    stays green under the new default-selection behavior.
- `swift test` must pass (host target, no UIKit); iOS-only views stay under `#if canImport(UIKit)`.
