# COF: brand logo and card management (design)

Status: awaiting approval. Size: small change (short design).

## Intent

Two improvements to the saved-card (COF) UI:

1. A saved-card row shows the card brand's **logo** instead of the brand name text.
2. The user can **delete** a saved card from the full saved-card list page via a "Manage" mode.

## Goals

- `SavedCard` carries an optional `logoUrl` (backend field, not available yet); rows render it.
- The full saved-card list page (opened by the home "View more" control) has a header action
  "Manage" / "Done". In manage mode each row shows a trailing delete button; tapping it asks for
  confirmation, then deletes.
- The delete backend call is a stub for now and is tracked in `docs/real-api-integration-checklist.md`.

## Non-goals

- Any manage action other than delete (the UI leaves room for more later).
- Real delete wiring (backend endpoint not provided).
- Disk caching of logos (the existing loader is memory-only and stays so).

## Constraints

- Core stays UI-agnostic; the content layer talks to the outside only through
  `CheckoutContentDelegate` (AGENTS.md §2.6).
- Only `CredentialStore` holds `customerAccessSecret`; the content layer never sees it.
- `CofService` and `SavedCard` are public: changes must be additive so host implementations keep compiling.
- The logo request sends only the URL (no cookies/credentials), as `CardBrandLogoLoader` already does.
- English only in code and docs.

## Approaches considered

- **A. Add `deleteCard` to `CofService` with a default implementation (chosen).** Hosts' existing
  implementations still compile. Call chain: content -> delegate -> container -> `CheckoutController`
  -> `cofService`.
- B. New public `CofManagementService` protocol. Enlarges the public init and host surface for a small feature.
- C. Content layer takes a delete closure. Bypasses the controller and `CredentialStore`; rejected.

## Design

### Model and service
- `SavedCard` gains `public let logoUrl: URL?` (init parameter defaulted to `nil`, so the change is additive).
- `CardItemWire` gains optional `logoUrl: String?`; `HTTPCofService.map` parses it, treating an invalid
  or non-http(s) URL as `nil` (a bad logo must not drop the card).
- `CofService` gains `func deleteCard(savedCardId: String, customerAccessSecret: String, sessionId: String) async throws`
  with a protocol-extension default that throws `CheckoutError` "unsupported".
- `HTTPCofService.deleteCard` is an explicit stub that throws the same unsupported error, with a comment
  pointing to the checklist. No request is made.
- `CheckoutController` gets `deleteSavedCard(id:) async throws`, reading the secret from `CredentialStore`
  and calling `cofService.deleteCard`. It reports no secret in errors or diagnostics.

### Delegate and container
- `CheckoutContentDelegate` gains `content(_:didRequestDeleteSavedCard:completion:)`, completion
  delivering success or failure on the main actor.
- `PaymentSheetContainerViewController` forwards to the controller (via the existing runCheckout-style seam).

### UI
- `SavedCardRow`: leading brand badge becomes an image view (about 30x24, aspect-fit, same slot size as
  `CardBrandIconsView`). It loads `logoUrl` via `CardBrandLogoLoader`; with no URL or a failed load it
  keeps the current text badge. Accessibility label still reads brand + last4.
- `SavedCardRow` gets a manage mode: hides the expiry, shows a trailing delete button, ignores row taps
  (selection disabled). Delete button has an accessibility label.
- `SheetHeaderView` gets a trailing text action ("Manage" / "Done") shown only on the full list page,
  taking the slot of the hidden close button. Its enabled state follows the same lock as close/back
  while a confirm is in flight.
- `SavedCardListView` exposes `setManaging(_:)` and `onDelete(id)`, and can remove a row.
- `CheckoutContentViewController`:
  - "View more" on the home summary shows for any non-zero number of saved cards (previously 2+).
  - Leaving the list page (back) exits manage mode.
  - Delete tap -> confirmation alert (cancel / destructive delete) -> delegate request.
  - On success: remove the card from `savedCards`; if it was selected, clear the selection; rebuild the
    home summary; if no cards remain, leave manage mode and return home.
  - On failure: keep the card, show an inline notice using the existing notice mechanism; stay in manage mode.
  - The row being deleted shows a busy state and rejects a second tap until the request returns.
- Localization: new keys in `en` and `zh-Hans` for Manage, Done, Delete, the confirmation title/message,
  and the delete-failed notice.

### Tracking
- `docs/real-api-integration-checklist.md`: add an item "Delete saved card" (endpoint, request/response
  and error codes unknown; `HTTPCofService.deleteCard` is a stub) and an item "`card/list` returns
  `logoUrl`" (field name and format to confirm).
- `docs/product-spec.md`: update the COF section for the logo and manage mode.

## Left to the builder
- Exact copy for the strings, icon/size polish, and the busy-state visuals.
- Where the "unsupported" error maps in `CheckoutError` (reuse an existing case if one fits).
- Tests: update existing tests whose behavior changes (the 2+ "View more" rule); do not add more than asked.
