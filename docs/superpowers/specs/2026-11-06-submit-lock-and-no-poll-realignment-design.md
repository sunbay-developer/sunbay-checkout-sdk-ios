# Submit-lock scope & no-client-poll realignment — design

Date: 2026-11-06
Status: DRAFT — awaiting review before implementation
Scope: Core (`CheckoutController`, `ResultPoller`, `PendingReconciliationStore`), UI
(`PaymentSheet` auto-reconcile), Wallet (`ApplePayButton`, `WalletAuthorizing`), docs
(`AGENTS.md`, `product-spec.md`).

> This document realigns the iOS SDK to the **intent** of the Web-side checkout submit contract —
> not a line-by-line port. The goal is narrow: **fix the lock logic and remove the client-side
> polling / cross-attempt reconciliation that can wedge the user, to improve UX.** Where the Web
> contract targets a problem that does not exist on iOS (e.g. the cross-process iframe collection
> boundary), we adapt to the native shape instead of copying the Web mechanism. Chinese appears
> only in this external spec artifact and in conversation, never in repo code (AGENTS.md rule 2).

### What we deliberately do NOT port from Web
- **`VALIDATION_ERROR` signal.** Web needs it to unblock its submit coordinator across an iframe
  boundary (the coordinator can't see inside the card iframe, so it must receive an explicit
  "validation failed" message instead of waiting on a timeout). iOS has no such boundary: the card
  form and the submit coordinator are in the same process / same synchronous call stack, and
  validation failure is already handled in-place (`handleConfirmNewCard` returns before any lock /
  request). So iOS needs no `VALIDATION_ERROR` code and no code change here — see Rule C below.
- **A `paymentStateKnown` boolean flag.** iOS already models this as two distinct enum cases
  (`.pending` / `.unknown`), which is stronger than a flag (the compiler forces the host to handle
  both). We keep the two cases.

---

## 1. Why

A Web-side contract was adopted to fix a class of "stuck checkout" bugs: after a failure (especially
form-validation failure, or an async-undetermined backend result) the submit lock was never
released, so every later action (retry / switch card / switch method) was rejected — the user was
wedged. Two root causes:

1. Lock release depended on a poll that might never terminate (no terminal state → never released).
2. Form-validation failure had no explicit signal; it fell back to a timeout, which was both slow
   and misread upstream as "result unknown", wedging the lock.

The iOS SDK has the **same two root causes, plus more**: it additionally carries a client-side
bounded poller (`ResultPoller`, ~90s) and a cross-attempt reconciliation layer
(`PendingReconciliationStore`) that the Web contract does not want. This realignment removes the
client poll, shrinks the lock to the in-flight submit request, and makes validation failure explicit.

This supersedes the earlier "query first, reconcile across attempts" design for the lock/poll
behavior (AGENTS.md rule 5 and the reconciliation layer are rewritten below).

---

## 2. The contract (3 core rules + wallet rule + 3-state result)

### Rule A — the submit lock covers ONLY the in-flight submit request
- The lock (`isConfirming`) is held only from the moment `submit` is dispatched to the moment it
  returns. It releases the instant the request returns — success / business-failure / network error
  / 5xx / "processing" — via a finally-equivalent (`defer`), never scattered per branch.
- Lock release NEVER depends on a poll / async callback / backend terminal state.
- Duplicate-charge protection rests on two things only: (1) holding the lock while the request is
  in flight (one submit at a time), and (2) the backend deduping by `attemptId` / `txnId`. It does
  NOT rest on freezing the UI.

### Rule B — the SDK does not poll on the merchant's behalf
- No client-side polling of the backend payment result. Async-undetermined results (wallets, etc.)
  are not waited out.
- As soon as the submit/authorization has a result, the SDK reports it to the merchant honestly.
  Async-undetermined → return `pending` (unknown), and the merchant/server resolves it via webhook
  or their own query.
- (Mirrors Stripe: the low-level SDK/Element layer does not client-poll wallets; only a high-level
  full-page HPP UI may poll. Our L1 PaymentSheet is still SDK-level here, so it does not poll.)

### Rule C — validation failure = handled in-place, never blocks (iOS already satisfies this)
- The contract's intent: a validation failure must not wedge the flow and the user must be able to
  fix and retry immediately. On Web this needs an explicit `VALIDATION_ERROR` to cross the iframe
  boundary; on iOS it is already true structurally. `handleConfirmNewCard` with `cardInput == nil`
  shows an in-place field error and returns BEFORE taking the lock or sending any request, so the
  user can edit and retap at once. **No error code, no outcome, no code change required for iOS.**

### Wallet rule — Apple Pay shares one lock; every ending releases it
- Wallet and card share the same submit lock (same `CheckoutController` actor). One submit at a time.
- The lock covers "wallet interaction + submit request" and releases on ANY definite ending:
  - wallet sheet canceled → release, return `canceled` (NOT `failed`);
  - wallet authorization failed → release, return `failed`;
  - authorization success → submit → submit request returns (success / fail / pending) → release.
- Never park on "await the backend async terminal state". All wallets treated alike.

### 3-state result semantics (do not collapse to 2 states)
| State       | Meaning            | When |
|-------------|--------------------|------|
| `succeeded` | definitely succeeded | backend returns a success terminal state |
| `failed`    | definitely failed    | validation failed / backend explicit decline / auth failure |
| `pending`*  | unknown / processing | request sent but no definite response (network err / 5xx / timeout), or backend says processing |

\* `pending` MUST NOT be reported as `failed` (money may already be captured; a false `failed` makes
the merchant re-charge → duplicate). On iOS this maps to the existing `.pending` / `.unknown` cases
(see §4, decision D). Neither is ever reported as `.failed`.

---

## 3. Current iOS state vs the contract (audit)

| Rule | Status | Where it diverges today |
|------|--------|-------------------------|
| A (lock = in-flight submit only) | ❌ | `CheckoutController` `defer { endAttempt() }` spans the whole confirm; `mapSnapshot(.initial)` runs `poller.pollUntilTerminal` (≤90s) and `.requiresAction` runs `actionHandler.handle` — all under the lock. |
| B (no client poll) | ❌ | `ResultPoller.pollUntilTerminal` called in `mapSnapshot(.initial)` (inline, lock held) and in `reconcile()` (driven by `PaymentSheet` auto-reconcile task). |
| C (validation handled in-place, never blocks) | ✅ | `handleConfirmNewCard()` with `cardInput == nil` shows a local field error and returns before any lock/request — already satisfies the intent. No change needed (and no `VALIDATION_ERROR` code, per §"What we deliberately do NOT port"). |
| D (async→pending, never failed) | ⚠️ partial | `.unknown(sessionId:)` already means "unknown, look up later" and is never `failed` (good); but it is a separate case, not a flag on `pending` (acceptable — see decision D). |
| Wallet | ❌ | `ApplePayButton.handleTap` collapses cancel AND auth-failure into one `catch { return }` — no `onResult`, cancel indistinguishable from failure. Success path shares the lock and waits out `.initial` polling. |
| 3-state | ⚠️ basic | `CheckoutOutcome` has all 5 cases; gap is only the missing poll removal + wallet cancel/fail split. |

---

## 4. Decisions locked for this plan (confirm before implementation)

- **Decision 1 — rewrite the hard rule.** AGENTS.md rule 5 currently says "query by
  session/transaction first — never blindly resubmit" and implies client reconciliation. It is
  rewritten (see §6) to: lock = in-flight submit only; SDK does not poll; async-undetermined →
  pending; recovery is the host's `retrievePayment`. **This edits a non-negotiable rule — needs
  explicit sign-off.**
- **Decision 2 — keep `.pending` AND `.unknown` as two cases (do NOT add a `paymentStateKnown`
  flag).** The two-case model is stronger than a boolean and already matches the Web semantics.
  → CONFIRMED in conversation.
- **Decision 3 — do NOT add `VALIDATION_ERROR`.** iOS has no cross-process collection boundary, so
  validation failure is already handled in-place with no lock and immediate retry. Nothing to build.
  → CONFIRMED in conversation (adapt to native shape, don't port the Web signal).

---

## 5. Implementation plan (2 steps)

### Step 1 — Rules A + B: remove the client poll and the inline wait (Core + PaymentSheet)
File: `Sources/SunbayCheckout/Core/CheckoutController.swift`
- `mapSnapshot(.initial)`: STOP calling `poller.pollUntilTerminal`. Map `.initial` directly to
  `.pending(txnId:)` (request returned "processing" / non-terminal → report pending, do not wait).
- `mapSnapshot(.requiresAction)`: keep delegating to `actionHandler.handle` (that is a client-side
  step-up decision, not a backend poll) — but assert the handler does not itself block on a backend
  terminal state (first release has no step-up UI → it returns `.pending`, which is correct).
- `submitAndMap`: keep the single "query-once on submit throw" (`getResult` one shot) — this is a
  one-shot reconciliation of a lost response within the SAME in-flight attempt, not a poll, and it
  keeps a dropped-response from wedging a duplicate. On that query failing → `.unknown`.
- Remove the cross-attempt reconciliation layer:
  - delete `reconcileIfPending` / `resolveReconciled` and their calls at the top of each confirm;
  - delete `reconcile(sessionId:)` (query-only poll);
  - delete the `pendingStore` field and `PendingReconciliationStore.swift`;
  - delete the `serverTerminal` plumbing in `submitAndResolve` / `submitAndMap` (no arm/disarm left).
- The lock (`defer { endAttempt() }`) now naturally spans only submit (+ the one-shot query on
  throw) + the synchronous `mapSnapshot` mapping — i.e. the in-flight submit request. No poll, no
  await on backend terminal state.
- `ResultPoller`: becomes unused. Delete `Sources/SunbayCheckout/Core/ResultPoller.swift` and
  `PollConfig`, and drop the `poller` init parameter from `CheckoutController`.

File: `Sources/SunbayCheckout/UI/PaymentSheet/PaymentSheet.swift`
- Remove the auto-reconcile machinery: `startReconcile` / `reconcileFinished` / `cancelReconcile`
  / `reconcileTask` / the injected `reconcile` closure / `.reconciled(...)` user action / the
  "still reconciling" transition. On `.pending` / `.unknown`, apply the outcome once, show the
  neutral info notice ("we're confirming; you can close; we won't double-charge"), and let the host
  reconcile via `retrievePayment`. (`product-spec.md` §page-state already says pending/unknown are
  non-visible states handled by `retrievePayment` — this makes the code match the spec.)

### Step 2 — Wallet rule: split cancel vs failure (Wallet)
Rule C needs NO code change (see §3 audit + §"What we deliberately do NOT port"); it is already
satisfied. The only remaining behavioral gap after Step 1 is the wallet cancel/failure split.

File: `Sources/SunbayCheckout/UI/Wallet/WalletAuthorizing.swift` (protocol) + its PassKit impl
- Make `authorize` distinguish user-cancel from authorization-failure. PassKit:
  `PKPaymentAuthorizationController` finishing with no authorization = user cancel; an authorization
  error = failure. Model as either a dedicated `WalletAuthorizationError.canceled` vs `.failed`, or a
  thrown typed error the button can switch on.
File: `Sources/SunbayCheckout/UI/Wallet/ApplePayButton.swift`
- `handleTap` catch: cancel → `onResult(.canceled)`; auth failure → `onResult(.failed(txnId: nil,
  error: ...))`; success → `confirmWallet(token:)` and return its outcome. The lock is the same
  actor lock; with Step 1 done it already releases once submit returns (no poll wait).

---

## 6. Doc changes

### AGENTS.md rule 5 — rewrite (Decision 1)
From:
> 5. **Payment truth = server-confirmed terminal state.** Wallet authorization success only means a
>    token was obtained, not that the transaction succeeded. On timeout / app relaunch, query by
>    session/transaction first — never blindly resubmit.

To (proposed):
> 5. **Payment truth = server-confirmed terminal state; the SDK does not poll for it.** Wallet
>    authorization success only means a token was obtained, not that the transaction succeeded. The
>    submit lock covers only the in-flight submit request and is released the moment the request
>    returns (success / failure / processing), never waiting on a poll or backend terminal state.
>    The SDK does not client-poll the backend for the result: an async-undetermined result is
>    reported as `pending` / `unknown` (never `failed`), and the host reconciles via
>    `retrievePayment` / webhook. On a lost response within one in-flight attempt the SDK may query
>    once (not a loop) before concluding `unknown`; it never blindly resubmits.

### product-spec.md
- §2.1 Core bullet "幂等(attemptId)/ 结果去重 / 提交失败先查询": keep idempotency + result-dedup +
  single query-on-failure; remove any implication of a bounded poll loop or cross-attempt
  reconciliation store.
- Data-flow blocks (§ around lines 292–315): the "网络失败/超时 → 不重发, getResult(sessionId) 对账"
  stays (one-shot), but any "I → 轮询至终态/90s" wording tied to `ResultPoller` is removed; `I` maps
  straight to `pending`.
- §page-state (lines 172–175): already correct (pending/unknown non-visible, host reconciles) — no
  change beyond confirming the auto-reconcile task is gone.

---

## 7. Self-check (must all be true after implementation)
- [ ] Submit lock held only during the real network request; released in a finally-equivalent on
      return (incl. throw/timeout), regardless of result.
- [ ] No path where the lock stays held awaiting a callback/poll. (`ResultPoller` deleted.)
- [ ] Validation failure: handled in-place before any lock/request; immediate retry (already true,
      no code change).
- [ ] Async-undetermined → `pending`/`unknown` (never `failed`).
- [ ] No SDK-internal backend-result polling remains (inline `mapSnapshot(.initial)` and
      `reconcile` both gone).
- [ ] Wallet cancel → `.canceled`; auth failure → `.failed`; submit-returned → lock released.

---

## 8. Tests impacted (update, do not expand beyond the change — AGENTS.md §4)
Expected to change or be removed (exact list finalized during implementation):
- Tests asserting the 90s/backoff poll ladder and `ResultPoller` behavior → removed with the poller.
- Tests asserting cross-attempt reconcile / `PendingReconciliationStore` arm-disarm, and the
  `reconcileIfPending` gate → removed with that layer.
- `mapSnapshot(.initial)` tests: now assert `.pending` instead of a polled terminal/unknown.
- PaymentSheet auto-reconcile tests (`startReconcile` / `.reconciled`) → removed; replace with a
  test that `.pending`/`.unknown` shows the neutral notice and returns without polling.
- New/updated: wallet cancel → `.canceled`, wallet auth-failure → `.failed` (needs the
  `WalletAuthorizing` double to emit the two distinct endings).
Verification: `swift test` (host) green, and an iOS build
(`xcodebuild -scheme SunbayCheckout -destination 'generic/platform=iOS Simulator' build`) green for
the UIKit/PassKit files.

---

## 9. Risk / open questions
- `WalletAuthorizing` cancel-vs-failure split may require touching the PassKit adapter and the
  `ApplePayProbe`; confirm the protocol change is acceptable (it is internal, not public API).
- Removing `.pending` inline polling means a backend that only ever returns `I` on submit now yields
  `pending` immediately; confirm the demo app + host guidance reflect "reconcile via retrievePayment".
- `product-spec.md` lives under `docs/` but is Chinese, which technically conflicts with AGENTS.md
  rule 2 ("docs/ in English"). Pre-existing; NOT addressed here. Flag separately if desired.
