# Real-API integration checklist

Things the SDK builds against a mock or a bundled copy today, and what must be done when the real
backend is ready. Read this before wiring any real endpoint. Add a section here whenever a feature
is built ahead of its API, and remove the section only after the item is verified end to end.

## 1. Card brand rules and BIN recognition

Contract: `docs/card-rules-contract.md` (the HPP server hosts both endpoints; the SDK never calls
the payment backend directly for this). The endpoints already exist and the JS SDK uses them
(confirmed by the owner, 2026-11-12), so everything below is SDK-side work, not a backend dependency.

Decision 2026-11-13 (`docs/superpowers/specs/2026-11-13-card-rules-sync-design.md`): **rules sync is
implemented; BIN recognition is deferred on iOS.** HPP's rules are enough for formatting hints and no
BIN should leave the device yet. The BIN items below stay open on purpose.

State today:

- Rules: `HTTPCardRulesService` (conditional `GET /api/card/rules`), time-gated background refresh
  (once per hour per process, triggered when a card form is built in the PaymentSheet and in Elements),
  cache in `Caches`, bundled copy produced by `scripts/update-card-rules.sh`. The services stay
  `internal` (not injectable by hosts), like the address service.
- BIN: `CardBinService` / `CardSchemeResolver` exist and are tested but run with `EmptyCardBinService`.

### 1.1 Rules service (done)

- [x] HTTP adapter for `GET /api/card/rules`, built on `SunbayAPIClient` (`getRaw`, no envelope).
- [x] Protocols stay `internal` (decided: no public injection; small public surface).
- [x] Threaded `SunbayCheckout` → `UIWiring` → `PaymentSheet` / `CheckoutElements` → `NewCardEntryView`.
- [x] ETag handling: the client session has no URL cache; the stored ETag is sent verbatim.
- [x] Short timeout (3 s), no retry, invalid / oversized / unknown-schema documents ignored.
- [ ] Real-device check against a deployed dev endpoint (see 1.4).

### 1.2 BIN recognition (deferred)

- [ ] `HTTPCardBinService` for `POST /api/card/bin` (envelope, success `code == "0"`), 3 s timeout, no
      retry; map `429` (`HTTP_429`) to `CardBinServiceError.rateLimited`.
- [ ] Inject it in place of `EmptyCardBinService` in `NewCardEntryView` callers (PaymentSheet content VC
      and `CardElement`).
- [ ] **Never log** the BIN, the request body or the response. Send at most 9 digits, only with a
      `sessionId`; never a full PAN.
- [ ] Privacy paperwork when enabled: BIN data flow in `docs/security-and-pci.md` and the DingTalk PCI
      doc, `PrivacyInfo.xcprivacy` re-check, tell integrators about privacy labels.

### 1.3 Data

- [x] The bundled rules are the HPP document (`scripts/update-card-rules.sh`, never edited by hand).
- [x] The contract's test vectors (§6) run against the bundled document
      (`CardRulesContractVectorsTests`).
- [ ] Re-run `scripts/update-card-rules.sh --check https://checkout.sunbay-dev.com/api/card/rules` after
      the HPP `dinersclub` rename is deployed to every environment, and then **remove the temporary
      `diners` → `dinersclub` alias** in `CardRuleSet`.
- [x] HPP-side maintenance and sync guide: checkout repo `docs/card-rules-maintenance.md`.
- [ ] Hook `scripts/update-card-rules.sh --check` into CI as a drift warning (no CI config in this repo).
- [ ] Ask HPP to add `autoAdvanceLength` for the brands that omit it, and `maestro` / `mir` if wanted
      (the draft bundle had them; the HPP document does not).

### 1.4 Behavior to verify on a real device with the real API

- [ ] Cold start offline: bundled rules, input works, no spinner or delay.
- [ ] Cold start online: rules refresh in the background and apply the **next** time the card
      component is shown, never mid-typing.
- [ ] Rules unavailable or invalid: the previous rules stay; payment is never blocked.
- [ ] Diners Club number formats and shows the Diners icon with both the old (`diners`) and the new
      (`dinersclub`) HPP document.

### 1.5 Privacy and security paperwork

- [x] `docs/security-and-pci.md` records the rules request (public data, `Caches`) and that no BIN is sent.
- [ ] Confirm the HPP endpoints are covered by the host app's ATS (HTTPS only) — no exceptions.

### 1.6 Cleanup once the rules are live

- [ ] Remove or shrink the local heuristics that exist only because no rules were available: the
      prefix table in `CardFormView.isCompletePAN` and the length/prefix checks in
      `CardScanParser` (`isPlausible`). They may stay as a last-resort fallback if the bundled
      rules are ever empty, but they must not disagree with the rules document.
- [ ] Scanning deliberately still requires Luhn for every brand (including UnionPay) as the guard against
      misreads; non-Luhn UnionPay cards must be typed by hand. Revisit only if that proves to be a real problem.
- [ ] Replace the demo mock BIN and rules services with the real adapters when BIN is enabled (Example;
      Showcase moved to `showcase-ios` and creates real dev sessions), and keep a scriptable test double
      in `SunbayCheckoutTestSupport`.
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
- [x] Backend renames session `storeCard` to `supportStoreCard`. Done on the backend (confirmed by the owner,
      2026-11-12; not yet re-verified with a live call). The SDK reads only `supportStoreCard` (absent means `true`),
      so no SDK change is needed.
- [ ] Unknown or malformed currency codes are now rejected (`INVALID_RESPONSE`); confirm the backend's
      currency table only issues codes Foundation knows.
- [x] In-doubt submit business codes: the SDK treats a non-network business error on submit as a
      definite failure. The only candidate seen so far, `E03` "System busy, please try again later" on
      HTTP 200 (observed 2026-11-09), is returned only for failed payments (user confirmation, 2026-11-09).
      Re-check if the backend introduces a "processing" business code.
- [ ] `getResult` after a lost submit may return a previous attempt's terminal state for the same session
      (confirm with the backend).
- [ ] Release gate: the `PrivacyInfo.xcprivacy` collected-data declaration (payment info, device info sent
      to the backend) is OPEN and must be decided before an App Store release (ruling R8).
- [ ] Product/legal must confirm whether the backend requires a consent record when `storeCard` is true
      (the UI checkbox still reads as consent).
- [x] Card list via the real adapter (`HTTPCofService`, `POST card/list`, verified 2026-11-09): a wrong
      `customerAccessSecret` returns `S06`; a missing one returns `C16`. Listing failures degrade to "no saved cards".
- [ ] Delete saved card: the endpoint, request/response shape and error codes are not provided yet.
      `HTTPCofService.deleteCard` is a stub that makes no request and throws `CARD_DELETE_UNSUPPORTED`; the UI
      (Manage mode, confirmation, remove-on-success, failure notice) is built against it. Wire the real call,
      then map its error codes. Until then every delete attempt fails with the "Couldn't delete" notice, so
      decide before release whether to hide the Manage action (release blocker).
- [ ] `card/list` returns `logoUrl` per card: confirm the field name, URL format (http(s), image type/size) and
      CDN reachability from the app. Until then rows show the text brand name.
- [ ] Does a `storeCard: true` new-card submit also need `customerAccessSecret` to bind the card to the
      customer? The `C01` requirement is resolved by sending `payerBillingInfo` (the SDK now does). Whether
      `customerAccessSecret` is needed on store-card submit is still unanswered until a store-card channel exists.
- [x] Backend `supportStoreCard` rename is deployed (confirmed by the owner, 2026-11-12).
- [x] `E03` is returned only for failed payments, so treating it as a definite failure is correct
      (confirmed by the user, 2026-11-09). This resolves the `E03` candidate above.
- [ ] `R` with a redirect returns `pending` without a result query or polling; revisit when QR payments
      are supported (user decision, 2026-11-09).
- [x] Real new-card payment end to end: passes against dev as of 2026-11-09 (submit `S` + `retrievePayment`).
- [x] `payment/result` responses omit `sessionId` (observed 2026-11-09); the SDK falls back to the queried session.
- [x] Saving a card was blocked on the merchant's store-card channel; the channel is now configured (confirmed by
      the owner, 2026-11-12). Follow-up still open: re-run `RealAPICofTests.testStoreThenPayWithSavedCard` against dev
      (opt-in, needs `SUNBAY_DEV_SERVER_URL`) to confirm the card appears in `card/list`.
      History of the blocker (live facts, dev, 2026-11-09): `storeCard: true` without `payerBillingInfo`
      is rejected with `C01` "Request parameter missing:payerBillingInfo is null" (with or without
      `customerAccessSecret`). With a billing address the dev merchant returns `txnStatus F` "No available
      channel" (a `tokenId` is returned but the card does not appear in `card/list`). Unblocking needs
      (a) the SDK to send `payerBillingInfo` (done in phase 3) and (b) the backend/merchant store-card channel
      configured. `RealAPICofTests.testStoreThenPayWithSavedCard` is expected to fail at step 1 until (b).
      Phase 3 check: `RealAPIAddressTests.testNewCardWithHostBillingAddressIsNotC01` asserts the new-card
      submit with `save: true` and a host billing address no longer fails with `C01`.
      Observed result: on 2026-11-09, with the sandbox test card and a host billing address on dev, the
      store-card submit returns `failed` with SDK code `PAYMENT_FAILED` (backend `F` "No available channel"),
      no longer `C01`. The billing-address requirement is therefore satisfied by phase 3; the only remaining
      blocker is the merchant's store-card channel.
      Decision (user, 2026-11-09): the SDK capability stays as is (the "save this card" checkbox stays
      visible under the effective COF rule; no SDK-side hiding or workaround). The billing-address
      requirement and the store-card channel are fixed in coordination with the backend; re-run
      `testStoreThenPayWithSavedCard` with the sandbox test card once the backend change lands.
- [ ] Apple Pay real-device verification (capability, wallet sheet, token accepted by the backend).
- [x] Dev origin accepts SDK requests (observed 2026-11-09, no WAF block).
- [ ] WAF behavior for native clients on test and production (headers, rate limits).

### Address (phase 3)

- [x] Address metadata live on dev (2026-11-09): `GET /api/address/country` returns 16 countries plus the
      detected country; `GET /api/address/country/US` returns fields, layout and 50+ subdivisions
      (`RealAPIAddressTests.testAddressMetadataCountriesAndUSConfig`).
- [x] Address submit: `payerBillingInfo` / `payerShippingAddress` are sent from the host address or the form.
- [ ] Postal code to state auto-fill is deferred (user decision).
- [ ] Google address autocomplete is deferred and needs an HPP proxy: a browser Maps key cannot be used
      from apps. Options: HPP proxy (recommended), Google Places SDK for iOS with per-bundle keys, MapKit
      `MKLocalSearchCompleter`.

- Product follow-up: partial "same as billing" (copy address fields, still collect shipping name/phone) was removed in the address-rules change; restore if product wants it.

Integrator notes (phase 3):

- Saved-card payments send only usable host-provided addresses (the SDK address form exists only on the
  new-card page). Wallet payments use the address returned by the wallet, else the usable host entry. Hosts
  whose sessions require an address for saved-card payments must pass a complete `billingAddress` /
  `shippingAddress`.
- Address API simplification: visibility follows the session's `collect…Address` flag; the host can only
  disable a form via `Appearance.billingAddressEnabled` / `shippingAddressEnabled` (default `true`), and
  `…AddressStyle` (`.simple` / `.full`) only changes the look. The public `AddressCollectionMode` enum and
  `…AddressMode` properties were removed before the first release (no tags exist yet).

### Wallet, address rules, payment-method filter and diagnostics

Behavior corrections to unreleased phase 3 (include in the first release notes; nothing shipped before them):

- Host address gating: a host address is used only when the session collects that kind and the address is
  complete (billing: country, city, line1, postal code; shipping: those plus first name, last name and phone).
  An incomplete entry is not used and reported as `ADDRESS_INCOMPLETE`.
- Form over host: a shown form with a draft wins over the host entry (reported as `ADDRESS_ENTRY_IGNORED`);
  `.automatic` hides the form for a kind that has a usable host entry. The earlier "host always wins" behavior
  is gone.
- Apple Pay now requests billing / shipping contacts per the rules in `docs/product-spec.md` §2.1 and §3.2, and
  saved-card payments send usable host entries only.

Cross-repo items:

- [ ] Register `WALLET_PARAMS_INVALID` in the shared `WARNING_CODES` and in the JS `api.md` code table (the JS
      SDK owns the table; the iOS code already emits it).
- [x] Apple Pay merchant id and certificate onboarding for the dev/test merchants (backend): done (confirmed by
      the owner, 2026-11-12). Still to verify on a real device: an Apple Pay payment succeeds end to end.

Open verification items on a real device (Apple Pay cannot be exercised on the simulator or in `swift test`):

- [ ] The Apple Pay sheet requests and returns the billing / shipping contacts as configured (postal address,
      name, shipping phone).
- [ ] The token format the backend accepts for `APPLE_PAY` (the SDK sends the PassKit payment data as is).
- [ ] The backend accepts the `customerName` / `customerEmail` the SDK derives from the wallet contacts.

Verified live on dev (2026-11-09) by `RealAPIWalletTests`: the `APPLE_PAY` entry's `ewalletParam` decodes with
non-empty networks and capabilities and builds a request with country `US`; the session lists `CARD`-typed
entries and `APPLE_PAY`, and `hide: ["CARD"]` removes every card entry while keeping Apple Pay. The new-card
submit with a host billing address (`RealAPIWalletTests.testNewCardWithHostBillingAddressIsNotC01`) needs the
sandbox test card in the environment and skips without it.

Still built ahead of their API (phase 2+):

- Saved-card list: now real (`HTTPCofService`); end-to-end save-then-pay now depends only on the backend
  store-card channel being configured (see above).
- Address metadata and address submit are now real (see "Address (phase 3)" above). Open there: postal code
  to state, and Google autocomplete.
- Card rules and BIN: section 1.

## Card brand icons from the session (built ahead of real data)

The card-number field shows the session's `paymentMethods[].logoUrl` icons (2 fixed + a rotating slot while
empty, the matched brand while typing; design: `docs/superpowers/specs/2026-11-10-card-brand-icons-design.md`).

- [ ] Verify against the live dev session that every `CARD` entry returns an `https` `logoUrl` and that the
      logo host is reachable from a real device (entries without a usable logo are skipped; with none the
      field falls back to the system card glyph).
- [ ] Verify `method` values (`VISA`, `MASTERCARD`, `AMEX`, `DISCOVER`, `JCB`, `DINERSCLUB`, `UNIONPAY`)
      match the rule-set scheme keys case-insensitively, so the matched icon shows while typing.

## Address validation and payment failure reasons (built ahead of verification)

- [ ] Postal-code `required` / `pattern` from `/api/address/country/{code}` is now enforced on new-card
      submits (`.simple` and `.full` share `DynamicAddressFormView`). Verify the real backend patterns on dev
      for US, CA, GB and CN: that valid postal codes pass and invalid ones block Pay.
- [ ] The fallback config (system country list, postal required, no pattern) is local only. It is used when
      metadata fails or is empty and is not backed by any backend contract. Confirm this is acceptable.
- [ ] `failureReason` text is shown as `CheckoutError.message` (code `PAYMENT_FAILED`). Verify that its language
      follows `Accept-Language`, and that it contains no sensitive data.
- [ ] `PaymentSheet` loads the session once per presentation, with no session-expiry re-check between attempts.
      Verify that an expired session produces a backend rejection that is shown inline.
- [ ] Manual dev check still open: a declining card keeps the sheet open and shows the failure reason.
- [ ] The fallback postal field is required with no pattern, so a payer in a country without postal codes (for
      example HK or AE) cannot pay while address metadata is down. Product decision pending.
- [ ] Ask backend/web whether postal `pattern`s are case-sensitive (for example lowercase UK input).
- [ ] `CheckoutController.start` holds the secrets before `loadSession`, so a failed start leaves them held
      until the sheet is dismissed. Possible follow-up.
- [ ] A server `failureReason` is shown as is (not localized). Mention in the release notes.

## Saved-card expiry and API source (2026-11-11)

- [x] Expired saved cards are detected locally from `expiryMonth` / `expiryYear` (valid through the end of
      the expiry month): listed last, dimmed with an "Expired" label, never pre-selected, never submitted.
      Replace with a backend card `status` once `card/list` returns one.
- [ ] `docs/api/*.json` are local snapshots and are already behind the backend (for example the merchant
      transaction query API added on 2026-11-09 is missing). Connect the API platform MCP and treat the live
      definitions as the source of truth before wiring any new endpoint.

## Debug network logging (2026-11-11)

`SunbayAPIClient.send` can log request/response messages for debugging. All gates must pass:

- Compiled only in `DEBUG` builds (`NetworkDebugLogger`); absent from a host's Release build.
- Only for the `.dev` environment.
- Only when the app is launched with the `-SunbayNetworkLog` argument (Xcode scheme > Arguments).

Output goes to `os.Logger` (subsystem `com.sunbay.checkout`, category `network`); filter in Console.app
or Xcode. JSON values are redacted by key (secret, token, encrypt, cipher, cvv/cvc, password,
authorization, signature, card number, ...) at any depth, and non-JSON bodies print only their size.
This is not a way to inspect secrets; use a proxy (Charles/Proxyman) for that. When a new sensitive
wire field is added, extend `sensitiveKeyFragments` if its name is not already covered.

## Apple Pay merchant identifier on submit (2026-11-11)

Apple Pay submits now carry `digitalWalletInfo.applePay.merchantIdentifier` (the id the token was authorized with).

- [ ] Backend: align `docs/api/checkout-api.json` (field marked optional, "not consumed yet") with the dev
      behavior (submit rejected with `merchantIdentifier is required` when absent).
- [ ] Real-device check: an Apple Pay payment with the internal merchant id succeeds end to end.
- [x] How an integrator's own merchant id is registered with Sunbay: through the separate developer platform, where the
      integrator can also upload its own certificate (confirmed by the owner, 2026-11-12). The SDK still sends whatever
      the host configured; add this to the integration guide.

## Release gate

- [ ] **RELEASE GATE:** obtain written QSA / acquirer confirmation of the host's PCI scope for `CardElement` before shipping it to merchants (see `docs/security-and-pci.md` §9.4); until then recommend `PaymentSheet`.
