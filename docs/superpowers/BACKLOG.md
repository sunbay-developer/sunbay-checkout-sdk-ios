# Backlog

## Checkout UI — home-page polish (deferred by request)

With no saved cards, the home page shows only the express (Apple Pay) button and a single
"New card" entry, which can look sparse. This is intentionally left as-is for now: with
`Appearance.sheetSizing.mode == .adaptive` the sheet shrinks to fit its content, so no large empty
area is left hanging. Revisit before adding more payment methods:

1. Make the "New card" entry a richer card: icon, "Credit or debit card" title, a subtitle, and
   small supported-brand marks (VISA / MC / AMEX).
2. Add an amount / merchant summary at the top of the home page (`session.merchantName` plus a large
   `session.amount`). Home page only; sub-pages keep their own title (e.g. "New card").
3. Replace the plain "Or pay using" divider with section titles such as "Express checkout" and
   "Pay another way".

## Payment safety: no blind resubmit after pending/unknown

Status: deferred by user decision. Behavior is intentionally unchanged for now.

Risk: after a `.pending` / `.unknown` outcome the saved-card selection survives, the Pay button stays
visible, and a second tap goes through the `present()` loop to `CheckoutController.confirmSavedCard`
with a NEW `attemptId`, without querying the session result first. This conflicts with AGENTS.md hard
rule 5 (on timeout / unknown, query by session/transaction first; never blindly resubmit). The behavior
is pre-existing; the select-then-Pay flow makes it easier to trigger.

Code references:

- `PaymentSheet.swift:206-228` — after `.pending`/`.unknown` the loop awaits the next confirm; `applyOutcome`
  (`PaymentSheet.swift` ~:456-459) returns false, so the sheet stays open.
- `CheckoutContentViewController.swift` ~:365-370 / ~:425 — `returnToEditing` -> `refreshConfirmButtonState`
  keeps `selectedSavedCardId`, so Pay stays visible.
- `PaymentSheet.swift:283-289` — the second tap emits `.confirmSavedCard` -> `controller.confirmSavedCard`.
- `CheckoutController.swift:226-246` and `:285-290` — `beginAttempt()` generates a new UUID `attemptId` and
  submits again. The only "query first" is inside a single attempt after a submit throw
  (`CheckoutController.swift:309-314`), not across attempts.
- `PaymentSheet.swift:261` re-runs `controller.start` on every loop pass, and `terminalCleanupIfTerminal`
  clears credentials on `.unknown` (`CheckoutController.swift:375-381`).

Proposed fix when scheduled: after `.pending`/`.unknown`, lock Pay and clear the saved-card selection (or
force `retrievePayment()` first), and let the user retry only after a confirmed non-terminal result.
