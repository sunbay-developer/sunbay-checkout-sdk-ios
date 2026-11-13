# Card rules sync (rules only, BIN recognition reserved) — design

Status: short design, pending owner approval. Contract: `docs/card-rules-contract.md`.
Checklist: `docs/real-api-integration-checklist.md` §1.

## Intent

The SDK ships a bundled copy of the card-brand rules, and the HPP server owns the live copy
(`GET /api/card/rules`). The bundled copy goes stale, so the SDK must check the live document on its
own and overwrite its local copy whenever the live one changed. Today the cache store, the refresher
and the rules model exist, but nothing calls the refresher and no HTTP adapter exists, so the rules
are never refreshed.

## Goals

- A real `HTTPCardRulesService` (conditional GET with `If-None-Match`).
- The refresh is actually triggered, in both the PaymentSheet and the Elements `CardElement`.
- A valid new document replaces the cached one; it applies the next time a card form is shown, never
  mid-typing. Any failure or invalid document keeps the current rules.
- The bundled fallback is the HPP document itself, refreshed by a release script (never hand-edited),
  with a CI drift check.

## Non-goals

- **BIN recognition is out of scope for now** (owner decision, 2026-11-13). HPP's rules are enough for
  formatting hints, and the platform recognizer is an external, more precise source we do not want to
  depend on yet. `CardBinService`, `CardSchemeResolver` and `EmptyCardBinService` stay as they are
  (dormant, default empty); no `HTTPCardBinService`, no BIN leaves the device. Revisit later; the
  checklist keeps the BIN items.
- No public API change: both protocols stay `internal`, built inside `SunbayCheckout` like
  `HTTPAddressMetadataService`. The merchant cannot inject or intercept them (small public surface,
  AGENTS.md rule 3).

## Approaches considered

1. **Refresh on card form display, rules only (chosen).** Smallest, no privacy impact, uses the
   existing refresher and store.
2. Refresh at SDK init / session load. Wastes a request for sessions that never show a card form.
3. Rules plus BIN recognition now. Rejected for this round (see non-goals).

## Design

- `SunbayAPIClient` gets a raw GET (status, headers, body; no envelope decode, no automatic retry,
  3 s timeout, no URLCache — the session is already ephemeral, so a `304` is not swallowed).
  `HTTPCardRulesService` sends the stored ETag verbatim (including its quotes) as `If-None-Match`:
  `304` → `.notModified`, `200` → `.updated(bytes, etag)`, anything else → throws (refresher ignores).
  New route `cardRules` → `<origin>/api/card/rules`.
- `SunbayCheckout` builds the service and threads it to `PaymentSheet` / `CheckoutElements` →
  `NewCardEntryView` (replacing the hard-coded `EmptyCardRulesService`). The refresher is triggered
  when a card form is first built.
- **Cadence (my call):** the refresher currently claims "once per process". Change to: at most one
  check per hour per process (in-memory timestamp), checked when a card form is built. A long-lived app
  therefore still picks up changes; server `Cache-Control: max-age=300` keeps it cheap. Update contract
  §4.1 accordingly.
- `CardRuleSet.parse` stays strict (sanity bounds) but treats the scheme key `diners` as `dinersclub`
  (my call, defensive). See open items.
- Bundled rules: replace the draft with the HPP document; add `scripts/update-card-rules.sh`
  (fetch live → write file → print SHA) and a CI step that compares SHA-256 with the live ETag and
  warns on drift.
- Tests: adapter (200/304/4xx/5xx/garbage, ETag sent verbatim, no body logging), refresher cadence and
  invalid-document handling, wiring in both PaymentSheet and CardElement, contract §6 test vectors
  against the bundled document. Update docs: product-spec §7, checklist §1, `security-and-pci.md`
  (public non-sensitive rules cache; no BIN flow added), contract §4.1.

## Open items for HPP (found on the dev endpoint, 2026-11-13)

The live document differs from the contract:

- Diners is keyed `diners` in the HPP rules, but the backend (`cardScheme`, session `method`) says
  `DINERSCLUB`. This is a legacy leftover in HPP, not a requirement: `diners` comes from HPP's old
  local `CardType` union (`src/utils/bankcard.ts`, Jan 2026), and the card-rules commit (2026-11-07)
  kept it and added an alias in `src/utils/cardRules/scheme.ts` to bridge it. HPP's own 2026-11-05
  BIN design had set out to remove exactly this `diners`/`dinersclub` mismatch. The contract text
  (`dinersclub`) is the intended behavior. **Done 2026-11-13 (uncommitted, branch `fix/diners-scheme-key`
  in the HPP repo):** rules key renamed to `dinersclub`, alias table and the legacy `CardType`
  `diners` removed, tests updated (full suite 930 passing, tsc clean). Until that is deployed to
  every environment, the live document still says `diners`, so the SDK keeps a temporary alias
  `diners` → `dinersclub` in `CardRuleSet.parse`; remove it once HPP is deployed everywhere.
- HPP's page and the JS SDK (`Orchestrator`) both call `/api/card/bin`; iOS skipping it is a
  deliberate platform difference, not a gap.
- `autoAdvanceLength` is present only for Mastercard and Amex. For brands that omit it, the SDK
  never auto-advances once the brand is known (Visa 16 digits does not advance anyway, by contract).
- The draft bundled copy also had `maestro` and `mir`; the live document does not. Offline-first-launch
  behavior for those two brands changes to "generic".
- Checked: the live prefixes have no Discover/UnionPay overlap (`62` vs `6011`/`644–649`/`65`).
