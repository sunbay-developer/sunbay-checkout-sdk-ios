# COF Brand Logo and Card Management Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Show the card brand logo (backend `logoUrl`) on saved-card rows, and add a "Manage" mode on the full saved-card list page that lets the user delete a saved card (backend delete call is a stub for now).

**Architecture:** Additive public API (`SavedCard.logoUrl`, `CofService.deleteCard` with a default implementation). The delete request flows content VC -> `CheckoutContentDelegate` -> `PaymentSheetContainerViewController` -> `PresentationCoordinator` -> `CheckoutController` -> `CofService`, so `customerAccessSecret` stays inside `CredentialStore`. UI changes live in `SavedCardRow`, `SavedCardListView`, `SheetHeaderView` and `CheckoutContentViewController`; logos reuse `CardBrandLogoLoader`.

**Tech Stack:** Swift, UIKit (iOS-only views under `#if canImport(UIKit)`), Swift Concurrency, XCTest, SwiftPM.

**Spec:** `docs/superpowers/specs/2026-11-12-cof-brand-logo-and-manage-design.md`

## Global Constraints

- English only in code, comments, strings in code, tests and docs (AGENTS.md §2.2). Localized UI copy goes in the `.strings` files (`en`, `zh-Hans`).
- Core (`CheckoutController`, `CofService`, models) imports no UIKit (AGENTS.md §2.6). The content layer talks outward only through `CheckoutContentDelegate`.
- `CofService` and `SavedCard` are public: changes must be additive; existing host implementations must keep compiling.
- Only `CredentialStore` holds `customerAccessSecret`; never log or return it. Card ids are not secrets but must not appear in diagnostics beyond what exists.
- Logo requests send only the URL (no cookies/credentials); no disk cache. Reuse `CardBrandLogoLoader`.
- "More" (`sunbay.cof.viewMore`) on the home summary shows for **1 or more** saved cards.
- Do not commit unless the user asks; when committing, `git add` exact files, never `git add .`. Develop on a `feature/*` branch, not `main` (AGENTS.md §5).
- Do not add tests beyond what is asked; update tests whose behavior changes (AGENTS.md §4).
- Verification commands (run from repo root):
  - Host: `swift build` and `swift test` (UIKit code is excluded on macOS).
  - iOS: `xcodebuild -scheme SunbayCheckout-Package -destination 'platform=iOS Simulator,name=iPhone 16e' test` (compiles and runs the UIKit code and UI tests).

## Review Focus

- Deleting the **currently selected** card: selection must clear and the Pay button must not stay enabled for a deleted id. (Task 4)
- Deleting the **last** card: leave manage mode, return home, home summary disappears, no stale row. (Task 4)
- Delete **fails** (stub throws "unsupported" today): card stays, notice shows, still in manage mode, button re-enabled. (Task 4)
- Double-tap on delete / delete while a payment confirm is in flight: second request ignored. (Task 4)
- **Expired** cards are deletable in manage mode and cannot be selected. (Task 3)
- `logoUrl` that is empty, malformed, or non-http(s): card still listed, text badge shown. (Task 1, Task 3)

---

### Task 1: Model, wire parsing, `CofService.deleteCard`, controller method

**Files:**
- Modify: `Sources/SunbayCheckout/Core/Models/SavedCard.swift`
- Modify: `Sources/SunbayCheckout/Core/Network/HTTPCofService.swift`
- Modify: `Sources/SunbayCheckout/Core/CofService.swift`
- Modify: `Sources/SunbayCheckout/Core/CheckoutController.swift` (the `CheckoutErrors` enum near line 29, and a new method after `listSavedCards()` ~line 252)
- Modify: `Tests/SunbayCheckoutTests/Support/MockCofService.swift`

**Interfaces:**
- Produces:
  - `SavedCard.logoUrl: URL?`; `SavedCard.init(id:brand:last4:expMonth:expYear:logoUrl: URL? = nil)`.
  - `CofService.deleteCard(savedCardId: String, customerAccessSecret: String, sessionId: String) async throws`, with a public protocol-extension default that throws `CheckoutErrors.cardDeleteUnsupported()`.
  - `CheckoutErrors.cardDeleteUnsupported() -> CheckoutError` (code `"CARD_DELETE_UNSUPPORTED"`, category `.runtime`, message `"Deleting a saved card is not supported."`).
  - `CheckoutController.deleteSavedCard(id: String) async -> Result<Void, CheckoutError>`.

- [ ] **Step 1:** Add `logoUrl` to `SavedCard` (documented, `Equatable` still synthesized) with the defaulted init parameter placed last.
- [ ] **Step 2:** In `CardItemWire` add `let logoUrl: String?`. In `HTTPCofService.map`, parse it with a small helper `static func logoURL(_ raw: String?) -> URL?` that returns a URL only when it parses and its scheme is `http` or `https` (case-insensitive); anything else is `nil` and never drops the card. Pass it to `SavedCard`.
- [ ] **Step 3:** Add `deleteCard` to `CofService` plus the default in `public extension CofService`. Document that the default throws unsupported so existing host implementations compile.
- [ ] **Step 4:** In `HTTPCofService` add an explicit `deleteCard` that makes no request and throws `CheckoutErrors.cardDeleteUnsupported()`, with a comment: backend endpoint not provided yet, tracked in `docs/real-api-integration-checklist.md`.
- [ ] **Step 5:** Add `CheckoutErrors.cardDeleteUnsupported()` next to the other factories.
- [ ] **Step 6:** Implement `CheckoutController.deleteSavedCard(id:)`: if there is no `session`, `cofEffective` is false or no secret is held, return `.failure(CheckoutErrors.cardOnFileUnavailable())`; otherwise call `cofService.deleteCard(savedCardId:customerAccessSecret:sessionId:)` and return `.success(())`; on error, report it via `reporter?.error(_, sessionId:)` (as `listSavedCards` does, wrapping non-`CheckoutError` errors in code `"SAVED_CARD_DELETE_FAILED"`, category `.network`) and return `.failure`. It never throws.
- [ ] **Step 7:** In `MockCofService` add `deleteCallCount`, `lastDeletedCardId`, and `stubDeleteError(_:)`, with `deleteCard` recording the call and throwing the stub (used by existing-style tests later if wanted; no new tests are required by this plan).
- [ ] **Step 8:** Run `swift build` -> `Build complete!`, and `swift test` -> all pass.

---

### Task 2: Delegate, container and `PaymentSheet` plumbing

**Files:**
- Modify: `Sources/SunbayCheckout/UI/Content/CheckoutContentDelegate.swift`
- Modify: `Sources/SunbayCheckout/UI/Container/PaymentSheetContainerViewController.swift`
- Modify: `Sources/SunbayCheckout/UI/PaymentSheet/PaymentSheet.swift` (`PresentationCoordinator.init` / `presentSheet`, and the `PresentationCoordinator(...)` call in `present(from:)` ~line 297)

**Interfaces:**
- Consumes: `CheckoutController.deleteSavedCard(id:)`, `CheckoutErrors.cardDeleteUnsupported()` (Task 1).
- Produces:
  - `CheckoutContentDelegate.content(_ content: CheckoutContentViewController, didRequestDeleteSavedCard id: String, completion: @escaping @MainActor (Result<Void, CheckoutError>) -> Void)`, with a default in a protocol extension that calls `completion(.failure(CheckoutErrors.cardDeleteUnsupported()))` (so the three test delegates in `CheckoutContentViewControllerTests.swift` keep compiling).
  - `PaymentSheetContainerViewController.onDeleteSavedCard: (@Sendable (String) async -> Result<Void, CheckoutError>)?`.
  - `PresentationCoordinator.init(..., deleteSavedCard: @escaping @Sendable (String) async -> Result<Void, CheckoutError>, ...)`.

- [ ] **Step 1:** Add the delegate method (documented) and its default extension.
- [ ] **Step 2:** In the container, add `onDeleteSavedCard` and implement the delegate method: spawn `Task { @MainActor in completion(await onDeleteSavedCard?(id) ?? .failure(CheckoutErrors.cardDeleteUnsupported())) }`.
- [ ] **Step 3:** Add the `deleteSavedCard` init parameter and stored property to `PresentationCoordinator`; in `presentSheet` set `containerVC.onDeleteSavedCard = deleteSavedCard`. In `present(from:)` pass `deleteSavedCard: { [controller] id in await controller.deleteSavedCard(id: id) }`.
- [ ] **Step 4:** Run `swift build` and the iOS command from Global Constraints (build only is enough: add `build` instead of `test`) -> `BUILD SUCCEEDED`.

---

### Task 3: Row, list and header components

**Files:**
- Modify: `Sources/SunbayCheckout/UI/Content/Components/SavedCardRow.swift`
- Modify: `Sources/SunbayCheckout/UI/Content/Components/SavedCardListView.swift`
- Modify: `Sources/SunbayCheckout/UI/Content/Components/SheetHeaderView.swift`

**Interfaces:**
- Consumes: `SavedCard.logoUrl` (Task 1), `CardBrandLogoLoader.image(for:completion:)` (existing, `@MainActor`).
- Produces:
  - `SavedCardRow.init(appearance: ResolvedAppearance, card: SavedCard, expiredText: String? = nil, logoLoader: CardBrandLogoLoader? = nil, deleteLabel: String = "")`.
  - `SavedCardRow.onDelete: (() -> Void)?`, `SavedCardRow.setManaging(_ managing: Bool)`, `SavedCardRow.setDeleting(_ busy: Bool)`.
  - `SavedCardListView.init(appearance:cards:logoLoader:deleteLabel:expiredText:)` (existing parameters keep their meaning; new ones are defaulted: `logoLoader: CardBrandLogoLoader? = nil`, `deleteLabel: String = ""`), `onDelete: ((String) -> Void)?`, `setManaging(_ managing: Bool)`, `setDeleting(_ id: String, _ busy: Bool)`, `removeCard(_ id: String)`.
  - `SheetHeaderView.onAction: (() -> Void)?`, `setActionTitle(_ title: String?)` (nil hides it), `setActionEnabled(_ enabled: Bool)`.

- [ ] **Step 1: `SavedCardRow` logo.** Replace the brand label slot with a fixed 30x24 slot: an aspect-fit `UIImageView` (hidden until an image arrives) beside the existing text badge. When `card.logoUrl` and `logoLoader` exist, request the image; on a non-nil image show it and hide the text badge; otherwise keep the text badge. Accessibility label stays `"<brand> <last4>"`.
- [ ] **Step 2: `SavedCardRow` manage mode.** Add a trailing delete button (SF Symbol `trash`, tinted `appearance.danger`, accessibility label = `deleteLabel`, min 44x44 hit area) hidden by default. `setManaging(true)` hides the expiry label and any "View more" control, shows the delete button, and makes row taps no-ops (guard in `handleTap`); `setManaging(false)` restores. Expired rows must also show the delete button. `setDeleting(true)` disables the button and dims the row; `false` restores. Button tap calls `onDelete`.
- [ ] **Step 3: `SavedCardListView`.** Keep rows in an array plus the stack; wire each row's `onDelete` to `onDelete?(card.id)`; implement `setManaging`, `setDeleting`, `removeCard` (removes the row view and array entry). Pass `logoLoader` and `deleteLabel` to each row.
- [ ] **Step 4: `SheetHeaderView` action.** Add a trailing text button placed in the close button's slot (same trailing anchor and centerY), hidden by default, font `appearance.cardFieldFont`, color `appearance.primary`. Update the title's trailing constraint to also respect the action button's leading edge. `setActionTitle(nil)` hides it; a non-nil title shows it and sets the accessibility label to the title. Add `setActionEnabled` (dims at 0.4 like close when disabled).
- [ ] **Step 5:** Run the iOS build command -> `BUILD SUCCEEDED`.

---

### Task 4: Content VC manage flow, "More" for one card, strings

**Files:**
- Modify: `Sources/SunbayCheckout/UI/Content/CheckoutContentViewController.swift`
- Modify: `Sources/SunbayCheckout/Resources/Localizations/en.lproj/Localizable.strings`
- Modify: `Sources/SunbayCheckout/Resources/Localizations/zh-Hans.lproj/Localizable.strings`
- Modify: `Tests/SunbayCheckoutTests/UI/CheckoutContentViewControllerTests.swift` (`test_viewMore_visibleOnlyForMultipleCards` ~line 262)

**Interfaces:**
- Consumes: Task 2 delegate method; Task 3 component APIs.
- Produces (strings, both locales): `sunbay.cof.manage` ("Manage" / "管理"), `sunbay.cof.done` ("Done" / "完成"), `sunbay.cof.delete` ("Delete" / "删除"), `sunbay.cof.deleteConfirmTitle` ("Delete this card?" / "删除这张卡?"), `sunbay.cof.deleteConfirmMessage` (a format with `%@` for "<brand> •••• <last4>", e.g. "%@ will be removed from your saved cards." / "%@ 将从已保存的卡片中移除。"), `sunbay.cof.deleteFailed` ("Couldn't delete the card. Please try again." / "删除失败,请重试。").
- Test seam for tests (DEBUG): `tapManageForTest()`, `tapDeleteForTest(_ id: String)`, `confirmDeleteForTest()` (runs the alert's destructive action without presenting), `isManagingForTest: Bool`, `headerActionTitleForTest: String?`.

- [ ] **Step 1: state.** Change `savedCards` to `private var`; add `private var isManagingSavedCards = false`, `private var deletingCardIds: Set<String> = []`, and `private let logoLoader = CardBrandLogoLoader()`. Pass `logoLoader` (and `deleteLabel: localize("sunbay.cof.delete")`) into `SavedCardRow` creation in `makeSavedCardSummary()` and `SavedCardListView` creation in `makeFullSavedCardList()`.
- [ ] **Step 2: "More" for one card.** In `makeSavedCardSummary()` change `savedCards.count > 1` to `!savedCards.isEmpty` (inside the existing `if let card`), update the doc comments on that method and `viewMoreAffordance`, and update `test_viewMore_visibleOnlyForMultipleCards` (rename to `test_viewMore_visibleForAnySavedCards`): one card -> `isViewMoreVisibleForTest` is true; many -> true.
- [ ] **Step 3: header action.** In `showAllSavedCards()` header switch: `header.setActionTitle(localize("sunbay.cof.manage"))`. In `showHome()` and `showNewCardSubpage()` header switches: `header.setActionTitle(nil)` and call `exitManageMode()`. `configureHeader()` sets `header.onAction = { [weak self] in self?.toggleManageMode() }`.
- [ ] **Step 4: manage toggling.** `toggleManageMode()` flips `isManagingSavedCards`, calls `savedCardList?.setManaging(_:)`, and sets the action title to `sunbay.cof.done` when managing, else `sunbay.cof.manage`; then `reportContentHeightIfChanged()`. `exitManageMode()` sets the flag false and `savedCardList?.setManaging(false)`. `setInputsEnabled(_:)` also calls `header.setActionEnabled(enabled)`.
- [ ] **Step 5: delete flow.** `makeFullSavedCardList()` sets `list.onDelete = { [weak self] id in self?.confirmDelete(id) }`. `confirmDelete(_ id:)` ignores the call when locked (`stateMachine.state.isLockedAgainstNewConfirm`), when `deletingCardIds` contains `id`, or when the card is unknown; otherwise presents a `UIAlertController(.alert)` with title `sunbay.cof.deleteConfirmTitle`, message formatted from `sunbay.cof.deleteConfirmMessage` with `"<BRAND> •••• <last4>"`, a cancel action (reuse an existing cancel string if one exists, else add `sunbay.common.cancel` in both locales) and a destructive `sunbay.cof.delete` action that calls `performDelete(id)`.
- [ ] **Step 6: perform delete.** `performDelete(_ id:)` inserts `id` into `deletingCardIds`, calls `savedCardList?.setDeleting(id, true)`, then `delegate?.content(self, didRequestDeleteSavedCard: id) { [weak self] result in ... }` (when `delegate` is nil treat as failure). In the completion: remove from `deletingCardIds`; on `.failure` call `setDeleting(id, false)`, `notice.show(message: localize("sunbay.cof.deleteFailed"), severity: .error)` and `reportContentHeightIfChanged()`; on `.success` call `removeSavedCard(id)`.
- [ ] **Step 7: `removeSavedCard(_ id:)`.** Remove the card from `savedCards`; `savedCardList?.removeCard(id)`; if `selectedSavedCardId == id` set it to `nil` and set `savedCardList?.selectedPaymentMethodId = nil`; if `savedCards` is now empty: remove the list from `allSavedCardsStack`, set `savedCardList = nil`, and call `showHome()`; otherwise `reportContentHeightIfChanged()`. Also make `rebuildSavedCardSummary()` handle the empty case: when `savedCards` is empty and `savedCardSummary` exists, remove it from `homeStack` and set `savedCardSummary = nil` and `viewMoreAffordance = nil` (currently it returns early and would leave a stale row). Call `refreshConfirmButtonState()` after any change.
- [ ] **Step 8: strings.** Add all keys above to both `.strings` files.
- [ ] **Step 9: seams.** Add the DEBUG test seams listed in Interfaces next to the existing ones (~line 573-585); `confirmDeleteForTest()` must call `performDelete` for the id last passed to `tapDeleteForTest`.
- [ ] **Step 10: verify.** Run `swift build`, `swift test`, and the iOS `test` command from Global Constraints -> all pass (the updated "More" test included). Then, in the simulator or via the `SunbayCheckoutDemo` app (real dev backend), open the saved-card list, tap Manage, tap delete, confirm: expected result today is the "Couldn't delete the card" notice and the card remains (stub), and Done returns the header action to "Manage".

---

### Task 5: Docs

**Files:**
- Modify: `docs/real-api-integration-checklist.md` (section 2, "Payment and saved-card services")
- Modify: `docs/product-spec.md` (COF / saved-card UI section; the line near 469 describing the card list)

- [ ] **Step 1:** Add two unchecked items to the checklist section 2: (a) "Delete saved card: endpoint, request/response and error codes unknown; `HTTPCofService.deleteCard` is a stub that throws `CARD_DELETE_UNSUPPORTED`; the UI (Manage mode, confirm, remove-on-success) is built against it" and (b) "`card/list` returns `logoUrl` per card: confirm field name, URL format and CDN reachability; until then rows show the text brand".
- [ ] **Step 2:** Update `product-spec.md` COF UI text: rows show the brand logo (text fallback); "More" is shown for any saved card; the full list page has Manage/Done with delete (confirm, then remove; failure keeps the card and shows a notice); `CofService.deleteCard` exists with a default implementation.
- [ ] **Step 3:** Run `swift build` (docs change only; sanity).

---

## Self-Review Notes

- Spec coverage: model/service/controller (Task 1), delegate chain (Task 2), logo + manage + header action (Task 3), flow, "More" for one card, failure/last-card/selected-card handling, strings (Task 4), checklist + product-spec (Task 5). The "left to the builder" items in the spec (copy, error mapping) are decided in Tasks 1 and 4.
- Type names are used consistently across tasks: `deleteSavedCard(id:)`, `onDeleteSavedCard`, `didRequestDeleteSavedCard`, `setManaging`, `setDeleting`, `removeCard`, `setActionTitle`.
- Tests: per AGENTS.md §4 only the changed "More" test is updated; no new tests are added. Say so if you want tests for the delete flow (controller `deleteSavedCard`, `logoUrl` parsing, manage-mode behavior).
