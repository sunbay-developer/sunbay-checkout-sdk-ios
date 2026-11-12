# Embedded and flexible integration: roadmap and foundation (design)

Status: approved; Block 1 implemented (extra Core unit tests approved by the product owner). Size: project. This document fixes the overall direction and fully designs
**Block 1** (the internal foundation). Blocks 2-4 get their own design documents later.

## Intent

Today the SDK offers only a bottom-sheet `PaymentSheet` (L1) and a standalone `ApplePayButton` (L3). Some
merchants need to embed payment in their own screen, or own the Pay button and layout more deeply. We add
the integration tiers Stripe offers around its sheet, while keeping card data inside the SDK and the PCI
scope no heavier than today.

## Decisions already made (by the product owner)

- Follow Stripe's tiers: `PaymentSheet` (exists), `FlowController`, `EmbeddedPaymentElement`,
  `AddressViewController`.
- **Not supported:** `CustomerSheet`, `PaymentMethodMessagingElement`.
- **No atomic input components.** A merchant who wants fully custom fields uses our low-level API and
  carries the PCI responsibility. That API is a separate project (not in this roadmap; needs a compliance
  review first).
- `AddressViewController` is provided as an optional component. Address autocomplete comes in a later
  version, implemented inside the shared address form so every host of that form gets it.

## Roadmap (one design and one plan per block)

1. **Foundation (this document, fully designed):** extract the presentation-independent checkout logic and
   the saved-card/page state out of `PaymentSheet` and `CheckoutContentViewController`. No public API
   change, no behavior change.
2. **`EmbeddedPaymentElement`:** a self-sizing `UIView` of payment-method rows (saved cards, new card,
   Apple Pay) inside the host page; the card form opens in an SDK-owned sheet; the host owns the Pay button
   by default and calls `confirm()`; display-only `paymentOption`; height/selection delegate.
3. **`FlowController`:** the SDK's sheet picks the payment method; the host owns the Pay button.
4. **`AddressViewController`:** standalone address page over the shared address form.

## Key insight that sizes Block 1

Following Stripe's model, the embedded element is a **rows list**, not the whole checkout content made
inline. The card form keeps living in the existing sheet. So `CheckoutContentViewController` does **not**
need to become inline-capable (no configurable chrome, no non-scrolling mode, no host-owned scroll
coordination). Block 1 only extracts what the sheet, the embedded rows view and the flow controller will
share: the session driver and the saved-card/page state.

## Goals (Block 1)

- A UIKit-free `CheckoutSessionDriver` that owns: session load + method filtering + COF listing + host
  address resolution (today `PaymentSheet.loadContext`), confirm dispatch (today `PaymentSheet.execute`),
  and the close-outcome policy (`isUnresolved`, `outcomeOnClose`).
- A UIKit-free `UserActionChannel` that owns the "await next action / post action / cancel, with one
  buffered action and cancel-beats-buffered" plumbing (today inside `PresentationCoordinator`).
- The shared types (`UserAction`, `AttemptResult`, `CheckoutContext`, `ContextResult`) move out of
  `PaymentSheet` to top-level internal types; `PaymentSheet.UserAction` etc. stay as `typealias`es so
  existing tests compile unchanged.
- A UIKit-free `SavedCardSelection` model owning: the card list (usable first), selected id, default id
  (first usable), expiry policy, removal, and which ids are being deleted. The content VC and later the
  embedded rows view use it.
- Behavior and public API unchanged; all existing tests green (the 87 content tests keep their `...ForTest`
  seams).

## Non-goals

- Any public API, any new UI, the embedded element, or the flow controller.
- Moving the wallet (Apple Pay) flow, the confirm assembly, or page navigation out of the content VC. They
  need UIKit or the visible forms; they stay until a later block needs them.
- Changing the retry loop in `PaymentSheet.present`. It is sheet-specific policy and stays there; the
  embedded element will have its own driver of the driver.

## Constraints

- Core stays UI-agnostic (AGENTS.md §2.6): the driver and channel import no UIKit/PassKit, so they build
  and test under `swift test` on macOS. The driver must not take `Appearance`, `AddressCollectionMode` or
  `Appearance.AddressFormStyle` (all UIKit-gated). It takes a small `DriverOptions` value: `expressOff: Bool`
  and an injected closure `addressFormsShown: @Sendable (_ session: CheckoutSession,
  _ billingEntryUsable: Bool, _ shippingEntryUsable: Bool) -> (billing: Bool, shipping: Bool)`. `PaymentSheet`
  (already UIKit-gated) builds that closure from `AddressCollectionMode.resolveAddressMode` and the
  appearance, exactly as `loadContext` does today; the driver only passes the result to
  `controller.evaluateHostEntries`. No public API changes.
- Card values, wallet tokens and secrets never enter logs, new public types or stored properties beyond
  the existing `UserAction` hand-off (AGENTS.md §2.3-2.4). `CardInput` stays internal.
- Payment truth stays server-confirmed; no polling; no blind resubmit (AGENTS.md §2.5).
- English only in code and docs; no commits unless asked; feature branch, never `main`.

## Approaches considered

- **A. Extract a driver + channel + selection model, keep the retry loop in the sheet (chosen).** Smallest
  step that unblocks Blocks 2-3; low risk for the 87 content tests because the VC's views and seams stay.
- B. Also rewrite the content VC around a full view-model (page, confirm assembly, wallet). Larger and
  riskier, and unnecessary because Embedded does not host the content inline.
- C. Skip the refactor; copy `loadContext/execute` into the embedded element. Fast, but duplicates the
  filtering/COF/address rules and the buffering fix we already needed once.

## Design

### Files (new, Core)
- `Sources/SunbayCheckout/Core/Session/CheckoutSessionTypes.swift`: `CheckoutUserAction` (was
  `PaymentSheet.UserAction`), `CheckoutAttemptResult`, `CheckoutSessionContext`, `CheckoutContextResult`
  and `DriverOptions`.
- `.../Core/Session/CheckoutSessionDriver.swift`: `final class CheckoutSessionDriver: Sendable-safe`, init
  `(controller:, sessionId:, customerAccessSecret:, checkoutClientSecret:, billingAddress:, shippingAddress:,
  options: DriverOptions, walletAuthorizer: any WalletAuthorizing, walletMerchantId: String?,
  paymentMethodFilter: PaymentMethodFilter)`; `func loadContext() async -> CheckoutContextResult`;
  `func execute(_ action: CheckoutUserAction) async -> CheckoutAttemptResult`;
  `func retrievePayment() async throws -> PaymentSnapshot`; `static func isUnresolved(_:)`,
  `static func outcomeOnClose(lastKnown:)`.
- `.../Core/Session/UserActionChannel.swift`: `@MainActor final class UserActionChannel` with
  `func next() async -> CheckoutUserAction`, `func post(_:)`, `func cancel()`, `var wasCanceled: Bool`.
  Semantics preserved exactly from `PresentationCoordinator.awaitEvent/resumeAction`: at most one buffered
  action; a later cancel replaces it; cancel wins over a buffered action when both are pending.
  `cancel()` is the only way to cancel: it sets `wasCanceled = true` and posts `.cancel` (so `post(.cancel)`
  behaves identically). The channel is `@MainActor`; the driver is not main-actor-isolated.
- `.../Core/Session/SavedCardSelection.swift`: value type holding `cards`, `selectedId`, `deletingIds`;
  `defaultId`, `select(_:)`, `remove(_:)`, `isExpired(_:at:)`, `canSelect(_:)`, `beginDelete/endDelete`.
  Wraps `SavedCardExpiry`. Behavior is preserved exactly: `selectedId` starts `nil`; `selectDefault()` sets it
  to `defaultId` and the VC calls it exactly where it assigns the default today (building the home page when
  cards exist, and `showHome` when nothing is selected); `remove(_:)` clears `selectedId` when the removed card
  was selected and never auto-reselects (the VC re-applies the default on the home page as today). Localizing
  the "Expired" label stays in the VC; only `isExpired` moves. The VC keeps passing no cards to the model when
  the session offers no card (`cardAvailable == false`), as it does today.

### Changes to existing files
- `PaymentSheet.swift`: holds a `CheckoutSessionDriver`; `loadContext`, `execute`, `runCheckout`,
  `runAttempt`, `isUnresolved`, `outcomeOnClose` delegate to it; nested types become typealiases. The retry
  loop in `present` is unchanged; `PresentationCoordinator` uses `UserActionChannel` for its
  action/buffer/cancel plumbing and keeps only the UIKit presentation and the finish continuation.
- `CheckoutContentViewController.swift`: replaces `savedCards`, `selectedSavedCardId`, `deletingCardIds`,
  `defaultSavedCardId` and `expiredText` logic with a `SavedCardSelection`; behavior and all
  `...ForTest` seams unchanged.
- No change to `Public/*`, `ApplePayButton`, `CheckoutController` or `CofService`.

### Testing and verification commands
- Host: `swift build` and `swift test` (UIKit code is excluded on macOS; the new Core units run here).
- iOS (the real gate for the UIKit code and the 87 content tests):
  `xcodebuild -scheme SunbayCheckout-Package -destination 'platform=iOS Simulator,id=<booted simulator id>' test`
  (list devices with `xcrun simctl list devices available`; a name alone can be ambiguous).
- Known failure that also occurs on `main` and is unrelated: `BottomSheetLayoutTests.
  test_install_unmeasured_usesInitialHeightSoEntranceHasAFrame` (403.33 vs 403.5). The gate is "no new failures".
- Existing tests are the safety net (they reference `PaymentSheet.UserAction` / `CheckoutContext`; the
  typealiases keep them compiling).
- Per AGENTS.md §4 only update tests whose behavior changes. Because the driver, channel and selection are
  new Core units that run on the macOS host, the plan adds focused tests for the channel's buffering rules
  and the selection model (the two places where a subtle bug already occurred before); this is the one
  addition beyond "update changed tests" and is flagged for the product owner to veto.

## Open items left to the builder
- Exact names of the new top-level types (the ones above are proposals).
- Whether `CheckoutSessionDriver` is an `actor`, a `@MainActor` class or a plain `Sendable` struct; it holds
  only immutable inputs and calls the `CheckoutController` actor, so a `Sendable` final class is expected.
- The `DriverOptions` closure is built in `PaymentSheet` (already UIKit-gated).

## Questions to settle in Block 2 (recorded, not decided here)
- With the Stripe-style "continue" action the card form closes before `confirm()`. Holding plaintext card
  data in the element until then is not acceptable; the proposal is to encrypt at "continue" (via
  `CardEncryptor`) and hold only the ciphertext. Needs a check that the encrypted payload is valid until
  confirm (session expiry, any server-side nonce/timestamp).
- `confirm()` takes no amount; the amount always comes from the server-loaded session.
- Lifetime: when the element calls `controller.dismiss()` (host call vs deinit) and what happens to an
  unsettled `pending`/`unknown` attempt.
