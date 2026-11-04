# Backlog

## Payment safety: no blind resubmit after pending/unknown

Status: FIXED on branch `fix/no-resubmit-after-unknown` (Core reconciliation-first confirm + UI lock).

The gap (now closed): after a `.pending` / `.unknown` outcome the Pay button re-enabled and a second tap
minted a NEW `attemptId` and called `confirm*` again with no query-first across attempts, risking a
duplicate charge if the first attempt had actually succeeded server-side (AGENTS.md hard rule 5).

What changed:

- Core (the safety boundary): `CheckoutController` records the session whose last confirm ended
  `.pending` / `.unknown`. The next `confirmNewCard` / `confirmSavedCard` / `confirmWallet` for that session
  makes ONE bounded `getResult` instead of minting an `attemptId` and submitting: terminal `S` ->
  `.succeeded`, terminal `F` -> `.failed` (marker cleared, so the user's next tap is a clean fresh attempt),
  still non-terminal or the query throws -> `.unknown` (marker stays). It never submits in those cases.
- UI (belt and suspenders): `pending` / `unknown` enter a locked `.reconciling` content state (Pay hidden,
  inputs and navigation locked, "Confirming your payment. Please don't try again." notice, only the header
  X stays available). `.failed` still returns to an interactive state.
- `present()` now returns the last `.pending` / `.unknown` outcome (not `.canceled`) when the user closes
  the sheet, so the host knows to call `retrievePayment()`.

Deferred follow-up:

- Once the backend idempotency contract on `attemptId` is confirmed (docs/product-spec.md P0 item), consider
  reusing the SAME attemptId across the reconciliation-triggered retry (today a fresh attemptId is minted only
  after a confirmed `.failed`, which is correct; revisit if the backend wants attemptId-level retry linkage
  instead of relying purely on server-side getResult reconciliation).
- Session-level `F` assumption: the reconciliation gate disarms on any session-level terminal `F` because
  `PaymentSnapshot` has no attemptId (assumption: a new attempt moves the session off a previous `F`;
  documented in docs/product-spec.md §8 item 3). Possible mitigation once the backend contract is known:
  compare `snapshot.txnId` to the last attempt's txnId before disarming.
- Reconciling sheet has no in-sheet "check again" action: the user can only wait or close. Consider a
  low-frequency background re-check or a "Check again" button that drives the Core reconciliation.

## Custom bottom sheet — optional follow-ups

- Optional: drag-to-dismiss gesture on the sheet header (Stripe has none).
- Optional: XCUITest in the Demo covering present → tap backdrop → dismissed.

## Apple Pay gate — UX follow-up

- ApplePayButton currently lets the user authenticate in the Apple Pay sheet before the reconciliation gate refuses/reconciles an unresolved session (UX follow-up: check the gate before presenting the wallet sheet).
