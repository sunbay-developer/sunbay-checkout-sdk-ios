# Embedded Foundation (Block 1) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Extract the presentation-independent checkout logic (session driver, user-action channel) and the saved-card selection state out of `PaymentSheet` and `CheckoutContentViewController`, with no public API change and no behavior change.

**Architecture:** New UIKit-free Core units under `Sources/SunbayCheckout/Core/Session/` (`CheckoutSessionTypes`, `UserActionChannel`, `CheckoutSessionDriver`, `SavedCardSelection`) that build and test on the macOS host. `PaymentSheet` keeps its public API and its retry loop but delegates loading/dispatch to the driver and uses the channel inside `PresentationCoordinator`; its nested types become `typealias`es so existing tests compile unchanged. `CheckoutContentViewController` keeps its views and every `...ForTest` seam but stores saved-card state in a `SavedCardSelection`.

**Tech Stack:** Swift 5.9, Swift Concurrency, UIKit (iOS-only parts), XCTest, SwiftPM.

**Spec:** `docs/superpowers/specs/2026-11-12-embedded-foundation-design.md`

## Global Constraints

- Core stays UI-agnostic (AGENTS.md §2.6): the new Core files import only `Foundation`; they must not reference `Appearance`, `AddressCollectionMode`, `Appearance.AddressFormStyle` or any UIKit/PassKit type. `ApplePayAvailability`, `PaymentProviderRegistry`, `PaymentMethodModel`, `WalletAuthorizing` are Foundation-only and may be used.
- No public API change; no behavior change; `Public/*`, `ApplePayButton`, `CheckoutController`, `CofService` are untouched.
- Card values, wallet tokens and secrets never enter logs or new stored state; `CardInput` stays internal and is only carried inside `CheckoutUserAction` exactly as today.
- Payment truth stays server-confirmed; no polling; no blind resubmit (AGENTS.md §2.5).
- English only in code, comments, docs. Feature branch `feature/embedded-foundation`; never develop on `main`. Do not commit unless the user asks; when asked, `git add` exact files, never `git add .`.
- The product owner allowed extra tests for this block ("special case"): each new Core unit gets focused tests (listed per task). Existing tests whose behavior is unchanged are not rewritten.
- Verification commands (repo root):
  - Host: `swift build` and `swift test`.
  - iOS gate: `xcodebuild -scheme SunbayCheckout-Package -destination 'platform=iOS Simulator,id=<booted simulator id>' test > /tmp/ios-test.log 2>&1; grep -E "error: -\[|\*\* TEST" /tmp/ios-test.log | grep -v kTCC` (find ids with `xcrun simctl list devices available`; a device name alone can be ambiguous). Known unrelated failure on `main` as well: `BottomSheetLayoutTests.test_install_unmeasured_usesInitialHeightSoEntranceHasAFrame` (403.33 vs 403.5). The gate is "no new failures".

## Review Focus

- A user action posted while nobody is suspended (the unlock window after a `.failed`) must be buffered, not dropped; only one is buffered and the first wins; a cancel always wins. (Task 2)
- `cancel()` after a buffered confirm: the next `next()` returns `.cancel` and keeps returning `.cancel`. (Task 2)
- `loadContext` must not call `CofService.listPaymentMethods` when COF is not effective or when the host hides `CARD`. (Task 3)
- A session-load `CheckoutError` becomes `.startFailed(.failed)`; any other error becomes `.startFailed(.unknown)`. (Task 3)
- No available payment method after filtering -> `NO_PAYMENT_METHOD_AVAILABLE` and the controller is dismissed. (Task 3)
- Removing the selected saved card clears the selection and never auto-reselects; an expired card is never selectable and never the default. (Task 4)

---

### Task 1: Shared session types in Core (pure move)

**Files:**
- Create: `Sources/SunbayCheckout/Core/Session/CheckoutSessionTypes.swift`
- Modify: `Sources/SunbayCheckout/UI/PaymentSheet/PaymentSheet.swift` (nested `UserAction`, `AttemptResult`, `CheckoutContext`, `ContextResult` near lines 50-95 and ~455)

**Interfaces:**
- Produces (internal, Foundation-only):
  - `enum CheckoutUserAction: Sendable` with the same four cases and default arguments as today's `PaymentSheet.UserAction`: `confirmNewCard(CardInput, save: Bool, billing: AddressInput? = nil, shipping: AddressInput? = nil, billingFormShown: Bool = false, shippingFormShown: Bool = false)`, `confirmSavedCard(paymentMethodId: String)`, `confirmWallet(WalletAuthorization, billingFormShown: Bool = false, shippingFormShown: Bool = false)`, `cancel`.
  - `enum CheckoutAttemptResult: Sendable, Equatable { case startFailed(CheckoutOutcome); case outcome(CheckoutOutcome) }`.
  - `struct CheckoutSessionContext: Sendable` with the same members and defaults as `PaymentSheet.CheckoutContext` (`session`, `savedCards`, `cardOnFileEnabled`, `saveCardByDefault`, `billingEntryUsable = false`, `shippingEntryUsable = false`, `visibleEntries: [MethodEntry] = []`).
  - `enum CheckoutContextResult { case ready(CheckoutSessionContext); case startFailed(CheckoutOutcome) }`.
  - Inside `PaymentSheet`: `typealias UserAction = CheckoutUserAction`, `typealias AttemptResult = CheckoutAttemptResult`, `typealias CheckoutContext = CheckoutSessionContext`, `typealias ContextResult = CheckoutContextResult`.

- [ ] **Step 1:** Create the four types in `CheckoutSessionTypes.swift`, moving the doc comments with them. Delete the nested declarations from `PaymentSheet.swift` and add the four typealiases in their place.
- [ ] **Step 2:** `swift build` -> `Build complete!`, then `swift test` -> all pass.
- [ ] **Step 3:** Run the iOS gate command -> no failures except the known `BottomSheetLayoutTests` one (this proves the typealiases keep `PaymentSheet.UserAction` / `PaymentSheet.CheckoutContext` references in `CheckoutContentViewControllerTests`, `PaymentSheetRunCheckoutTests`, `PaymentSheetContainerDismissalTests` compiling).

---

### Task 2: `UserActionChannel` and its use in `PresentationCoordinator`

**Files:**
- Create: `Sources/SunbayCheckout/Core/Session/UserActionChannel.swift`
- Create: `Tests/SunbayCheckoutTests/Core/UserActionChannelTests.swift`
- Modify: `Sources/SunbayCheckout/UI/PaymentSheet/PaymentSheet.swift` (`PresentationCoordinator`, ~lines 525-800)

**Interfaces:**
- Consumes: `CheckoutUserAction` (Task 1).
- Produces: `@MainActor final class UserActionChannel` with `init()`, `func next() async -> CheckoutUserAction`, `func post(_ action: CheckoutUserAction)`, `func cancel()`, `private(set) var wasCanceled: Bool`.
  Semantics (copied from `PresentationCoordinator.awaitEvent/resumeAction`): if a continuation is waiting, `post` resumes it; otherwise it buffers: a `.cancel` replaces any buffered action, any other action is buffered only when the buffer is empty (first wins). `cancel()` sets `wasCanceled = true` and then posts `.cancel` (so `post(.cancel)` also behaves as a cancel for buffering, but only `cancel()` sets `wasCanceled`). `next()`: if `wasCanceled`, clear the buffer and return `.cancel` (every time); else return and clear the buffered action; else suspend.

- [ ] **Step 1: Write the failing tests** in `UserActionChannelTests` (host-runnable, `@MainActor`, use a small helper `isCancel(_:)` / `savedCardId(_:)` to match enum cases since `CheckoutUserAction` is not `Equatable`):
  - `test_next_returnsActionPostedWhileSuspended`: start `Task { await channel.next() }`, yield, `post(.confirmSavedCard(paymentMethodId: "pm_1"))`, assert the task result is `pm_1`.
  - `test_post_beforeNext_isBufferedAndDelivered`: post then `await next()` returns it.
  - `test_secondPostWhileBuffered_isIgnored_firstWins`: post `pm_1` then `pm_2`; `next()` returns `pm_1`; a following suspended `next()` is not satisfied by `pm_2` (assert via a short-timeout race or by posting `pm_3` and receiving `pm_3`).
  - `test_cancelReplacesBufferedAction`: post `pm_1`, then `post(.cancel)`; `next()` returns cancel.
  - `test_cancel_setsWasCanceled_andResumesSuspendedNext`: suspended `next()`, `cancel()`, task returns cancel, `wasCanceled == true`.
  - `test_cancelWinsOverLaterPost_andKeepsReturningCancel`: `cancel()`, `post(.confirmSavedCard("pm_9"))`, `next()` returns cancel twice in a row.
  - `test_postCancel_doesNotSetWasCanceled`: `post(.cancel)` leaves `wasCanceled == false` but a following `next()` still returns cancel from the buffer.
- [ ] **Step 2:** Run `swift test --filter UserActionChannelTests` -> FAIL (type not defined).
- [ ] **Step 3:** Implement `UserActionChannel` in `Core/Session/UserActionChannel.swift` (a `CheckedContinuation<CheckoutUserAction, Never>?` plus an optional buffered action).
- [ ] **Step 4:** Run `swift test --filter UserActionChannelTests` -> all pass.
- [ ] **Step 5:** In `PresentationCoordinator`, replace `bufferedUserAction`, `actionContinuation`, `awaitEvent`, `resumeAction`, and the `wasCanceled` stored flag with a `private let channel = UserActionChannel()` and: `awaitNextAction` returns `await channel.next()` after presenting; `containerVC.onUserAction = { channel.post($0) }`; in `handleContainerFinish(.canceled)` and the no-presenter branch call `channel.cancel()`; expose `var wasCanceled: Bool { channel.wasCanceled }` for `present()` and the `finishContinuation` check. Keep `finishContinuation`, `applyOutcome`, `dismiss`, `presentSheet` otherwise unchanged. Keep the doc comment explaining "no lost user action" on the channel.
- [ ] **Step 6:** iOS gate -> no new failures (`PaymentSheetRunCheckoutTests` includes the "second submit not dropped" case that pins the buffering behavior).

---

### Task 3: `CheckoutSessionDriver` and `PaymentSheet` delegation

**Files:**
- Create: `Sources/SunbayCheckout/Core/Session/CheckoutSessionDriver.swift`
- Create: `Tests/SunbayCheckoutTests/Core/CheckoutSessionDriverTests.swift`
- Modify: `Sources/SunbayCheckout/UI/PaymentSheet/PaymentSheet.swift` (stored dependencies, both inits, `loadContext`, `execute`, `runAttempt`, `runCheckout`, `retrievePayment`, `isUnresolved`, `outcomeOnClose`)

**Interfaces:**
- Consumes: Task 1 types.
- Produces:
  - `struct DriverOptions: Sendable { var expressOff: Bool = false; var addressFormsShown: @Sendable (_ session: CheckoutSession, _ billingEntryUsable: Bool, _ shippingEntryUsable: Bool) -> (billing: Bool, shipping: Bool) = { _, _, _ in (false, false) } }` (in `CheckoutSessionTypes.swift` or the driver file).
  - `final class CheckoutSessionDriver: Sendable` with `init(controller: CheckoutController, sessionId: String, customerAccessSecret: String?, checkoutClientSecret: String?, billingAddress: AddressInput?, shippingAddress: AddressInput?, options: DriverOptions, walletAuthorizer: any WalletAuthorizing, walletMerchantId: String?, paymentMethodFilter: PaymentMethodFilter)`; `func loadContext() async -> CheckoutContextResult`; `func execute(_ action: CheckoutUserAction) async -> CheckoutAttemptResult`; `func retrievePayment() async throws -> PaymentSnapshot`; `static func isUnresolved(_ outcome: CheckoutOutcome) -> Bool`; `static func outcomeOnClose(lastKnown: CheckoutOutcome) -> CheckoutOutcome`.

- [ ] **Step 1: Write the failing tests** in `CheckoutSessionDriverTests` (host-runnable; build a real `CheckoutController` with `MockPaymentService`, `MockCofService`, `CredentialStore()`, `StubActionHandler(result: .pending)` as `PaymentSheetRunCheckoutTests.makeController` does; add a tiny private `StubWallet: WalletAuthorizing` in the test file with `canMakePayments() -> false`, `missingParameters` returning `[]`, and `authorize` throwing a `CheckoutError`; build a session with `CheckoutSession(id:amount:merchantName:methods:expiresAt:rsaPublicKey:cofEnabled:)`). Tests:
  - `test_loadContext_cofEffective_listsSavedCards`: secret provided, `cofEnabled: true` -> `.ready` with the stubbed cards and `cof.listCallCount == 1`.
  - `test_loadContext_noSecret_doesNotListCards`: no `customerAccessSecret` -> `.ready` with `savedCards == []` and `cof.listCallCount == 0`.
  - `test_loadContext_hideCardFilter_skipsListing`: `PaymentMethodFilter(hide: ["CARD"])` with only card+savedCard methods -> `.startFailed(.failed(... code "NO_PAYMENT_METHOD_AVAILABLE" ...))` and `cof.listCallCount == 0`.
  - `test_loadContext_sessionLoadCheckoutError_mapsToFailed`: `payment.stubLoadError(CheckoutErrors.networkUnavailable())` -> `.startFailed(.failed(txnId: nil, error: <that error>))`.
  - `test_loadContext_sessionLoadOtherError_mapsToUnknown`: `payment.stubLoadError(URLError(.timedOut))` -> `.startFailed(.unknown(sessionId:))`.
  - `test_loadContext_passesUsableEntryFlagsToAddressClosure`: supply `billingAddress`/`shippingAddress` complete values and a recording `addressFormsShown` closure; assert it received `billingEntryUsable == true` for the usable kind and that the context carries the same flags.
  - `test_execute_cancel_returnsCanceled`: `execute(.cancel)` -> `.outcome(.canceled)`.
  - `test_execute_confirmSavedCard_returnsControllerOutcome`: after `loadContext`, `payment.stubSubmit([succeeded snapshot])`, `execute(.confirmSavedCard(paymentMethodId:))` -> `.outcome(.succeeded(...))` (mirror the snapshot construction used in `PaymentSheetRunCheckoutTests`).
  - `test_outcomeOnClose_and_isUnresolved_tables`: pending/unknown stay as-is; succeeded/failed/canceled map to `.canceled`; `isUnresolved` true only for pending/unknown.
- [ ] **Step 2:** Run `swift test --filter CheckoutSessionDriverTests` -> FAIL (type not defined).
- [ ] **Step 3:** Implement the driver by moving the bodies of `PaymentSheet.loadContext()`, `execute(_:)`, `isUnresolved`, `outcomeOnClose` and `retrievePayment` into it, replacing: `appearance.expressPosition == .off` with `options.expressOff`; the `AddressCollectionMode.resolveAddressMode(...)` pair with a call to `options.addressFormsShown(session, billingEntryUsable, shippingEntryUsable)`; and returning `CheckoutContextResult` / `CheckoutAttemptResult`. Everything else (filter, `reportFilterIgnored`, provider availability incl. `ApplePayAvailability.evaluate`, `reportWalletParamsInvalid`, `NO_PAYMENT_METHOD_AVAILABLE` + `controller.dismiss()`, COF decision, `controller.evaluateHostEntries`) stays identical.
- [ ] **Step 4:** Run `swift test --filter CheckoutSessionDriverTests` -> all pass.
- [ ] **Step 5:** In `PaymentSheet`, build one `CheckoutSessionDriver` in the internal init (capture `appearance.expressPosition == .off`, and for `addressFormsShown` capture the four appearance values `billingAddressEnabled`, `shippingAddressEnabled`, `billingAddressStyle`, `shippingAddressStyle` into locals and compute with `AddressCollectionMode.resolveAddressMode(.from(enabled:), collect: session.collectBillingAddress / collectShippingAddress, hasUsableEntry:, style:) != .off`, exactly as today). Make `loadContext()`, `execute(_:)`, `retrievePayment()`, `isUnresolved`, `outcomeOnClose`, `runAttempt`, `runCheckout` delegate to it, keeping their current signatures and the `present()` retry loop untouched. Remove the now-unused stored properties (`customerAccessSecret`, `checkoutClientSecret`, `billingAddress`, `shippingAddress`, `paymentMethodFilter`, `walletAuthorizer`/`walletMerchantId` only if no longer read by `PaymentSheet`; `present()` still passes the wallet authorizer/merchant id to the coordinator, so keep those two).
- [ ] **Step 6:** `swift build`, `swift test`, then the iOS gate -> no new failures.

---

### Task 4: `SavedCardSelection` and the content view controller

**Files:**
- Create: `Sources/SunbayCheckout/Core/Session/SavedCardSelection.swift`
- Create: `Tests/SunbayCheckoutTests/Core/SavedCardSelectionTests.swift`
- Modify: `Sources/SunbayCheckout/UI/Content/CheckoutContentViewController.swift` (stored properties near lines 44-60 and 160, `init` line ~247, `defaultSavedCardId`, `expiredText(for:)`, `removeSavedCard`, `performDelete`/`finishDelete`, `confirmDelete`, `handleConfirmSavedCard`)

**Interfaces:**
- Consumes: `SavedCard`, `SavedCardExpiry`.
- Produces: `struct SavedCardSelection` with
  `init(cards: [SavedCard], clock: @escaping @Sendable () -> Date = { Date() })` (stores `SavedCardExpiry.usableFirst(cards, at: clock())`),
  `private(set) var cards: [SavedCard]`, `private(set) var selectedId: String?`, `private(set) var deletingIds: Set<String>`,
  `var isEmpty: Bool`, `var defaultId: String?` (first non-expired card),
  `func isExpired(_ card: SavedCard) -> Bool`,
  `mutating func setSelectedId(_ id: String?)` (unchecked, mirrors today's direct assignment),
  `mutating func selectDefault()`,
  `@discardableResult mutating func select(_ id: String) -> Bool` (false when unknown, expired or deleting; does not change the selection then),
  `mutating func clearSelection()`,
  `mutating func remove(_ id: String)` (also clears `selectedId` if it equals `id` and removes it from `deletingIds`; never reselects),
  `@discardableResult mutating func beginDelete(_ id: String) -> Bool` (false when unknown or already deleting), `mutating func endDelete(_ id: String)`.

- [ ] **Step 1: Write the failing tests** in `SavedCardSelectionTests` (host-runnable; inject a fixed `clock` of 2026-11-12 and build cards with `SavedCard(id:brand:last4:expMonth:expYear:)`):
  - `test_init_ordersUsableBeforeExpired_keepingOrderWithinGroups`.
  - `test_defaultId_isFirstUsable_andNilWhenAllExpired`.
  - `test_selectedId_startsNil`.
  - `test_selectDefault_selectsFirstUsable`.
  - `test_select_rejectsExpiredUnknownAndDeletingCards_leavingSelectionUnchanged`.
  - `test_remove_selectedCard_clearsSelection_andDoesNotReselect`.
  - `test_remove_nonSelectedCard_keepsSelection`.
  - `test_remove_lastCard_makesIsEmptyTrue`.
  - `test_beginDelete_secondCallForSameIdReturnsFalse_andEndDeleteReenables`.
  - `test_setSelectedId_isUnchecked` (can set an expired id; pins the compatibility behavior used by the VC).
- [ ] **Step 2:** Run `swift test --filter SavedCardSelectionTests` -> FAIL.
- [ ] **Step 3:** Implement `SavedCardSelection`.
- [ ] **Step 4:** Run `swift test --filter SavedCardSelectionTests` -> all pass.
- [ ] **Step 5:** In the content VC replace the stored `savedCards`, `selectedSavedCardId`, `deletingCardIds` with `private var selection: SavedCardSelection`, keeping source-compatible computed accessors so the rest of the file and every `...ForTest` seam stay as they are: `private var savedCards: [SavedCard] { selection.cards }`, `private var selectedSavedCardId: String? { get { selection.selectedId } set { selection.setSelectedId(newValue) } }`, `private var deletingCardIds: Set<String> { selection.deletingIds }`, and `defaultSavedCardId` returns `selection.defaultId`. The init builds `selection` with `cardAvailable ? savedCards : []` (the model sorts usable first). `expiredText(for:)` keeps the localization: `selection.isExpired(card) ? localize("sunbay.cof.expired") : nil`. In `performDelete`/`finishDelete`/`removeSavedCard` use `beginDelete`/`endDelete`/`remove` instead of mutating the arrays directly (remove the `savedCards.removeAll`, the `selectedSavedCardId = nil` for the removed id and the `deletingCardIds.insert/remove` calls), keeping the UI reactions (list row removal, summary rebuild, `showHome` when empty) as they are.
- [ ] **Step 6:** Run the iOS gate. The 87 existing content tests (including the manage/delete and "More" tests) must still pass; no new failures except the known one.

---

### Task 5: Docs

**Files:**
- Modify: `docs/product-spec.md` (the architecture section describing `PaymentSheet` / Content / Container, near §2.5-§6; add the new Core/Session units and the driver boundary)
- Modify: `docs/superpowers/specs/2026-11-12-embedded-foundation-design.md` (status line; note that extra tests were approved)

- [ ] **Step 1:** Add a short "Session driver" paragraph to the architecture text: where the driver, channel and selection live, that `PaymentSheet` keeps the retry loop, and that Embedded/FlowController will reuse the driver.
- [ ] **Step 2:** Mark the spec status as "approved; Block 1 implemented" once Tasks 1-4 are green.
- [ ] **Step 3:** `swift build`, `swift test`, iOS gate once more as the final check.

---

## Self-Review Notes

- Spec coverage: types (Task 1), channel (Task 2), driver + `DriverOptions` closure (Task 3), selection model with the preserved edge semantics (Task 4), docs and verification commands (Task 5 and Global Constraints). The spec's open items (names, class kind) are decided here: names as proposed; `CheckoutSessionDriver` is a `final class` that is `Sendable` (all stored properties are immutable `Sendable` values, closures are `@Sendable`).
- Consistency: `CheckoutUserAction`, `CheckoutSessionContext`, `CheckoutContextResult`, `CheckoutAttemptResult`, `DriverOptions`, `UserActionChannel.next/post/cancel/wasCanceled`, `SavedCardSelection` members are named the same in every task.
- Risk: Task 2 and Task 4 touch code the existing UI tests pin (buffering, selection). Each task ends with the iOS gate so a regression is caught in the task that caused it.
