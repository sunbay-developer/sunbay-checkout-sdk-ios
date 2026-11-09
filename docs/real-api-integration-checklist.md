# Real-API integration checklist

Things the SDK builds against a mock or a bundled copy today, and what must be done when the real
backend is ready. Read this before wiring any real endpoint. Add a section here whenever a feature
is built ahead of its API, and remove the section only after the item is verified end to end.

## 1. Card brand rules and BIN recognition

Contract: `docs/card-rules-contract.md` (the HPP server hosts both endpoints; the SDK never calls
the payment backend directly for this).

State today (what was built ahead of the API):

- `Core/CardBrand/`: rule model + loader + sanity checks (`CardRuleSet`), prefix matching, bundled
  **draft** rules (`Resources/CardRules/card-brand-rules.json`), cache store and provider
  (`CardRulesProvider`: cached remote > bundled > minimal), background refresher, BIN resolver
  (`CardSchemeResolver`), and the **internal** protocols `CardRulesService` / `CardBinService` with
  fail-soft empty defaults.
- `CheckoutContentViewController` takes both services as init parameters defaulting to the empty
  ones; nothing above it passes them yet. No real HTTP adapter exists.
- `CardFormView` already groups, auto-advances and sizes the security-code hint from the rules, and
  validates leniently (number 12–19 digits, security code 3–4 digits).

### 1.1 Wire the real services

- [ ] Add HTTP adapters for `GET /api/card/rules` and `POST /api/card/bin`, modeled on
      `HTTPAddressMetadataService` (thin adapter, `baseURL` injected by the host, nothing hard-coded).
- [ ] The protocols are `internal` today. Make them `public` and inject them through
      `SunbayCheckout.init(...)` as optional parameters defaulting to `nil` (the fail-soft empty
      implementation). This adds public API: minor version bump, and update
      `docs/product-spec.md` §2 / §7.
- [ ] Thread them down the same path as `addressMetadataService`: `SunbayCheckout` → `PaymentSheet`
      (both its public and internal init) → the sheet runner → `CheckoutContentViewController`.
- [ ] Update `docs/product-spec.md` §7: the two endpoints move from "mock baseline" to real, and
      `AGENTS.md` rule 7 still applies (keep them behind protocols).

### 1.2 Networking details that are easy to get wrong

- [ ] **ETag with `URLSession`:** the shared `URLCache` can answer a conditional request itself and
      hide the `304` (the app sees a `200`). Decide one approach and test it: either use an
      ephemeral configuration with `requestCachePolicy = .reloadIgnoringLocalCacheData` and send
      `If-None-Match` manually from our own stored ETag, or rely on `URLCache` and drop our ETag
      store. Do not mix them.
- [ ] **Envelope:** `/api/card/rules` returns the raw rules document (no `{code,msg,data}`); only
      errors use the envelope. `/api/card/bin` always uses the envelope and success is `code == "0"`
      (string). Treat any other `code`, any non-2xx, and any decoding failure as "no result".
- [ ] **Timeouts and retries:** short timeout (about 3 s), no retries, never block input. The adapter
      must throw `CardBinServiceError.rateLimited` on a `429` (the resolver then stops for the session);
      any other error counts as a failure (3 in a row also stop it).
- [ ] **Never log** the BIN, the request body, or the response of `/api/card/bin`. No analytics
      events carrying them.
- [ ] Send the BIN only when `sessionId` is available; send at most 9 digits; never a full PAN.

### 1.3 Data

- [ ] Replace the bundled draft rules with the production document from the HPP repo.
- [ ] Add the release script that overwrites the bundled file from the live `GET /api/card/rules`
      at SDK build time, and the CI check that compares the bundled file's SHA-256 with the live
      ETag and warns on drift. The bundled file is never edited by hand.
- [ ] The backend's `cardScheme` is `VISA MASTERCARD AMEX DISCOVER JCB DINERSCLUB UNIONPAY` or `null`;
      rules use the lower-cased keys (note `dinersclub`, not `diners`). Re-check against the real
      endpoint, and confirm an unknown value falls back to local matching / `generic`.
- [ ] Run the contract's test vectors (section 6) against the Swift implementation using the
      production document, not only the draft.

### 1.4 Behavior to verify on a real device with the real API

- [ ] Cold start offline: bundled rules, input works, no spinner or delay.
- [ ] Cold start online: rules refresh in the background and apply the **next** time the card
      component is shown, never mid-typing.
- [ ] BIN conflict: the local prefix guess is replaced by the backend scheme at 6 digits; the
      display re-groups without deleting any digit and without caret jumps.
- [ ] Editing the first digits of a number that already resolved a scheme re-resolves it.
- [ ] Backend returns `null` or fails: stays on the local guess, then on `generic`; payment is
      never blocked by a rules/BIN failure.
- [ ] The short-prefix flicker described in the contract (for example `62`) is acceptable.

### 1.5 Privacy and security paperwork

- [ ] `docs/security-and-pci.md`: add the BIN lookup (first 6–9 digits leave the device over TLS to
      the HPP server, never logged or persisted) and the public, non-sensitive rules cache in the OS
      cache directory.
- [ ] `PrivacyInfo.xcprivacy` now ships (no tracking, no collected data types). When the BIN call is
      added, re-check what the manifest must declare and tell integrators whether their privacy
      labels are affected.
- [ ] Confirm the HPP endpoints are covered by the host app's ATS (HTTPS only) — no exceptions.

### 1.6 Cleanup once the rules are live

- [ ] Remove or shrink the local heuristics that exist only because no rules were available: the
      prefix table in `CardFormView.isCompletePAN` and the length/prefix checks in
      `CardScanParser` (`isPlausible`). They may stay as a last-resort fallback if the bundled
      rules are ever empty, but they must not disagree with the rules document.
- [ ] Scanning deliberately still requires Luhn for every brand (including UnionPay) as the guard against
      misreads; non-Luhn UnionPay cards must be typed by hand. Revisit only if that proves to be a real problem.
- [ ] Replace the demo/showcase mock BIN and rules services with the real adapters (Example and
      Showcase), and keep a scriptable test double in `SunbayCheckoutTestSupport`.
- [ ] Keep Android and HPP on the same document and the same test vectors; a behavior change starts
      with the contract, then all three implementations.

## 2. Payment and saved-card services

Phase 1 (core payment path) is implemented: `SunbayAPIClient`, `HTTPPaymentService` (load, submit,
result), `SunbayCheckout(configuration:)` defaulting to the real backend, `checkoutClientSecret`
plumbing, device info, dev server (`Example/DevServer`) and the opt-in `SunbayCheckoutRealAPITests`
(`scripts/run-dev-e2e.sh`). Contract: `docs/product-spec.md` §7.

Verified live against dev:

- [x] Load session: `totalAmount` and other amount fields are decimal STRINGS in MAJOR units; the SDK
      converts to minor units by currency fraction digits. `expiresAt` is `yyyy-MM-dd HH:mm:ss` in UTC.
- [x] Create session with `sessionType: "sdk"` + `customerId` returns `checkoutClientSecret` (`ccs_`) and
      `customerAccessSecret` (`cas_`).
- [x] A 5xx on submit is ambiguous (one result query, then `unknown`).

Open verification items:

- [ ] Apple Pay token wire format in `cardEncryptedData` (today: UTF-8 of the token JSON via `WalletTokenEncoder`).
- [x] `paymentMethod` value for new cards is `CARD` (same as the web SDK submit controller).
- [x] Submit requires `sessionType`: without it the backend returns `C16` "Parameter cannot be
      empty:sessionType" (observed 2026-11-09). The SDK echoes the `sessionType` from the load-session
      response on every submit path.
- [ ] Backend renames session `storeCard` to `supportStoreCard`. The response still carries legacy
      `storeCard`; the SDK reads only `supportStoreCard` (absent means `true`). Re-check after deployment.
- [ ] Unknown or malformed currency codes are now rejected (`INVALID_RESPONSE`); confirm the backend's
      currency table only issues codes Foundation knows.
- [ ] Release gate: confirm with the backend that no submit business code means in-doubt (processing,
      acquirer timeout, upstream unavailable); any such code must be mapped to ambiguous. Until confirmed,
      the SDK treats a non-network business error on submit as a definite failure. Concrete candidate:
      `E03` "System busy, please try again later" on HTTP 200 (observed 2026-11-09 on a submit with an
      invalid ciphertext); ask whether `E03` can be returned after the payment was processed.
- [ ] `getResult` after a lost submit may return a previous attempt's terminal state for the same session
      (confirm with the backend).
- [ ] Release gate: the `PrivacyInfo.xcprivacy` collected-data declaration (payment info, device info sent
      to the backend) is OPEN and must be decided before an App Store release (ruling R8).
- [ ] Product/legal must confirm whether the backend requires a consent record when `storeCard` is true
      (the UI checkbox still reads as consent).
- [ ] Real new-card payment end to end (needs `SUNBAY_TEST_CARD_*` env for the opt-in tests).
- [ ] Apple Pay real-device verification (capability, wallet sheet, token accepted by the backend).
- [x] Dev origin accepts SDK requests (observed 2026-11-09, no WAF block).
- [ ] WAF behavior for native clients on test and production (headers, rate limits).

Still built ahead of their API (phase 2+):

- Saved-card list (`CofService`): mock baseline; `HTTPCofService` is phase 2 (`POST card/list`).
- Address metadata (`AddressMetadataService`): full-mode address is protocol, UI and cache only;
  `HTTPAddressMetadataService` exists but is not wired to real data. See the UI redesign spec.
- Card rules and BIN: section 1.
