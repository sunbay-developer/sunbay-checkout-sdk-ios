# Real API integration — design

Status: draft for review. Date: 2026-11-09.
Inputs: `docs/api/checkout-api.json` (checkout web API) and `docs/api/checkout.openapi.json` (open platform: create-session), `docs/real-api-integration-checklist.md`,
`docs/product-spec.md` §7, the HPP repo (`checkout`: `src/lib/rewrites.ts`, `src/app/api/**`,
`src/services/address.ts`) and the JS SDK (`checkout-sdk-web/js/src/config/env.ts`).

## 1. Intent

Payment, saved-card, address and card-rule features all run against mocks today. Replace the mocks
with real HTTP adapters so an ISV app can take a real payment, without changing Core or UI.
Delivered in four phases, each shippable and verifiable on its own.

## 2. Goals, non-goals, anti-goals

Goals
- Built-in adapters for all backend calls the SDK needs, behind the existing protocols.
- The host chooses only an **environment**; it never supplies a URL.
- Behavior matches what the HPP web page does against the same backend.

Non-goals
- No `baseURL` or host override in the public API.
- No new payment features (L2, new payment methods, polling). Existing rules in `AGENTS.md` §2.5 still hold.
- No change to Core state machine semantics beyond what the real contract forces (section 5).

Anti-goals (failure even if it "works")
- Any card value, wallet token, `customerAccessSecret`, `checkoutClientSecret`, request body or response
  body reaching logs, analytics or public callbacks.
- A rules/BIN/address failure blocking a payment.
- A silent resubmit after a lost response.

## 3. Constraints

- Swift only, English only, Core imports no UIKit (`AGENTS.md` §2).
- Everything is HTTPS to one origin per environment. No ATS exceptions.
- The backend contract is `docs/api/checkout-api.json` plus the HPP routes; where they disagree with the old
  mock baseline in `product-spec.md` §7, the real contract wins and §7 is updated.

## 4. Approaches

- **A. One origin per environment (HPP), everything through its `/api` forwarding. Chosen.**
  The HPP server already forwards `/api/checkout/*` to the backend (`rewrites.ts`) and serves
  `/api/address/*` and `/api/card/*` itself. The web page and the JS SDK use the same path. The SDK
  embeds one host table and one shared API client.
- B. HPP for address and card rules, backend gateway directly for payment. Saves one hop, but needs
  gateway hostnames we do not have, a second host table, and duplicates HPP's security/limit policy.
  Rejected.
- C. Keep host-injected services and ship only sample adapters. Rejected: the host would need to
  know backend URLs and secrets handling, which defeats an SDK.

Decided by the user: no `baseURL`, environment only, default production, all requests via HPP.

## 5. Design

### 5.1 Environments and URLs

`CheckoutConfiguration.Environment` already has `dev / test / production`. Internal `SunbayEndpoints`
maps it to an origin (same table as the JS SDK; verify before release):

| Environment | Origin |
|---|---|
| dev | `https://checkout.sunbay-dev.com` |
| test | `https://checkout.sunbay-uat.us` |
| production | `https://checkout.sunbay.us` |

| Capability | Method and path under `{origin}` |
|---|---|
| Load session | `POST /api/checkout/web/session/{sessionId}` |
| Submit payment | `POST /api/checkout/web/payment/submit` |
| Payment result | `POST /api/checkout/web/payment/result/{sessionId}` |
| List saved cards | `POST /api/checkout/web/card/list` |
| Countries / country config | `GET /api/address/country`, `GET /api/address/country/{code}` |
| Card rules / BIN | `GET /api/card/rules`, `POST /api/card/bin` |

(Pay By Link `POST /link/{linkId}` is not used by the native SDK.)

### 5.2 Shared client: `SunbayAPIClient` (internal, Foundation only)

- Ephemeral `URLSession`, no shared `URLCache`, no cookies.
- Headers: `Content-Type: application/json`, `Accept-Language` from the SDK locale, an SDK identification header.
- Decodes the `{code, msg, data, traceId}` envelope; success is `code == "0"` (string). Any other code,
  non-2xx or decode failure becomes a typed internal error carrying `code` and `traceId` only.
- Per-call timeouts; no automatic retry for submit. Idempotent GETs may retry once.
- Never logs URLs with identifiers beyond the path template, never logs bodies. Injectable `URLSession`
  (or `URLProtocol`) for tests.
- `/api/card/rules` returns a raw document, not the envelope; the client supports both response shapes.

### 5.3 Contract drift to absorb (old mock baseline vs real API)

| Topic | Mock baseline | Real contract | Impact |
|---|---|---|---|
| Saved-card pay | `paymentMethodId` | `paymentMethod="TOKEN"` + `savedCardId` + `customerAccessSecret` in the submit body | `SubmitRequest` fields change |
| Save a new card | `savePaymentMethod` + `consent` | submit body `storeCard: Bool` = save this payment's card | `consent` leaves the wire |
| COF available | `cofEnabled` in session | session `supportStoreCard` (renamed from `storeCard`, agreed with backend; default `true`). `false` forces COF off in the SDK | `CheckoutSession.cofEnabled` is fed by it; absent means `true` |
| List cards | GET, bearer secret | `POST card/list {sessionId, customerAccessSecret}` | `HTTPCofService` |
| Card item | `id,last4,expMonth:Int,expYear:Int` | `savedCardId, maskedCardNumber, cardBrand, expiryMonth "MM", expiryYear "YY", cardholderName` | mapper: last4 from masked number, YY to 20YY, brand lower-cased |
| Wallet token | open (P1) | sent in `cardEncryptedData` | closes spec §8 item 6; token encoding to confirm |
| Status | `S F I R` | `S F R` only | `I` is never received; pending/unknown is derived (below) |
| Address | `line1/line2` | `address/address2`; no `state` code guarantee, no `district` | mapper |
| Client secret | n/a | `checkoutClientSecret` in load and submit bodies | `CredentialStore` supplies it |
| Idempotency | `attemptId` | no field in the API | `attemptId` stays an SDK-local in-flight guard only |
| Device info | n/a | optional `userDeviceInfo` | SDK fills what iOS can provide |

Pending/unknown rule (keeps `AGENTS.md` §2.5): `R` with a known action goes to `ActionHandler`;
`R` with an unknown action or a lost/timed-out submit response triggers at most one `payment/result`
query, then `unknown`. `F` only from an explicit `F`.

### 5.4 Public API

- Add `SunbayCheckout(configuration:)` building the default HTTP services for the configured environment.
  Existing injecting init stays (examples, e2e, test support use it).
- `Consent` and the `paymentMethodId`/`savePaymentMethod` fields on the public `SubmitRequest` become
  obsolete. The repo has no release tags yet (`git tag` is empty), so **remove them outright**, no
  deprecation period. (My call.)
- **`checkoutClientSecret`** (required by the API for SDK scenarios) does not exist in the SDK yet. The host
  backend returns it with the session over HTTPS, exactly like `customerAccessSecret`. Add it as a
  parameter next to `customerAccessSecret` on `PaymentSheet` / `ApplePayButton` init, held in
  `CredentialStore` (memory only), sent in the load and submit bodies. (My call.)
- **`customerAccessSecret` expiry or revocation:** no refresh callback in the public API. The backend error
  maps to a typed `CheckoutError`; the saved-card section degrades to "new card only" and the payment
  can continue. (My call; revisit if the backend offers a refresh flow.)
- **RSA key:** comes from `LoadSessionResp.rsaPublicKey` (Base64), per session. `CardEncryptor` takes the key
  as an argument, so it stays synchronous and nothing is bundled or cached across sessions.
- **Lost submit response:** one `payment/result/{sessionId}` query. If the backend answers "not found" or
  the query also fails, the outcome is `unknown`, never `failed`. Same for every payment method. (My call.)
- Update `product-spec.md` §2 and §7, `AGENTS.md` (the "SDK ships no real adapter" wording),
  `real-api-integration-checklist.md`.

### 5.5 Phases

1. **Core payment path.** `SunbayEndpoints`, `SunbayAPIClient`, `HTTPPaymentService` (load, submit, result),
   Apple Pay token submit, new-card submit with RSA encryption, device info, result mapping.
   Exit: dev-environment sandbox payment succeeds for new card and Apple Pay on a real device.
2. **Saved cards (COF).** `HTTPCofService`, TOKEN payment, `storeCard`, model changes in 5.3.
   Exit: list, pay with a saved card, and save a new card against dev.
3. **Address.** Point `HTTPAddressMetadataService` at `/api/address/country*` through the shared client,
   reuse `AddressMetadataCache` (TTL and dedup), wire it as the default, add `AddressInfo` mapping to
   the submit body. Dynamic country list and country-specific field layout and linkage come from the
   server config. Fail-soft: if config cannot load, fall back to a minimal fixed form or block only
   the address step, never crash. Exit: full-mode address submits a valid `payerBillingInfo`.
4. **Card rules and BIN.** Adapters per checklist §1 (ETag approach decided there, `429` handling,
   bundled rules refresh, never log BIN). Exit: checklist §1.4 on device.

Each phase ends with: `swift test` green, contract fixtures updated, and the matching checklist items ticked.

### 5.6 Testing

- Contract fixtures derived from `docs/api/checkout-api.json` examples; `URLProtocol` stubs drive the client and
  adapters (envelope errors, non-2xx, timeouts, malformed JSON, lost submit response).
- Mappers (status, saved card, address) get table tests.
- A manual or opt-in dev-environment smoke target per phase; not part of default `swift test`.
- Showcase/Example apps get an environment switch; mocks stay available for UI work.

### 5.7 Session creation: a Node dev server in the repo (dev only)

Production flow: the merchant **server** calls the open platform `POST {open}/v1/checkout/create-session`
(Bearer API key, `appId`, `merchantId`) and hands `sessionId` + `checkoutClientSecret` (+ optional
`customerAccessSecret`) to the app. The SDK never creates sessions and never sees the API key.

We mirror the JS SDK example: a small dependency-free Node server (`example/server/session.mjs` +
`server.mjs` there). The iOS repo must stay self-contained, so we **copy and adapt** it, not reference the JS repo.

- Location: `Example/DevServer/` (`server.mjs`, `session.mjs`, `.env.example`, `README.md`). Node 20.6+, zero deps.
  Credentials (`API_KEY`, `APP_ID`, `MERCHANT_ID`, optional `OPEN_API_URL`, `CURRENCY`) come from a git-ignored
  `Example/DevServer/.env.local`. They never reach the app or the repo.
- Create-session body sends `sessionType: "sdk"` (fixed; open API value is lower-case `sdk`) and a `customerId`
  (from `CUSTOMER_ID` in `.env.local`, default a stable dev id so saved cards persist across runs), plus
  `supportStoreCard: true`. The open API issues `customerAccessSecret` only when `customerId` is sent. The response
  carries `sessionId`, `checkoutClientSecret` and `customerAccessSecret` together (no separate customer-grants
  call); the server passes them through.
- Credentials: `Example/DevServer/.env.local` is copied from the JS example's `.env.local` (same sandbox merchant);
  `.gitignore` must cover it before the copy.
- Endpoints: `POST /api/create-session` returns `{sessionId, checkoutClientSecret, customerAccessSecret?}`
  (body may carry items, currency, `collectBilling/ShippingAddress`); `GET /healthz` reports whether credentials
  are present. Binds `127.0.0.1` by default; a `HOST` env var allows LAN binding for real-device runs.
- The Example and Showcase apps call this server through a small `DevSessionClient` (a plain HTTP client that
  looks like a merchant-backend call). The server URL is configurable in the app (default `http://127.0.0.1:8095`;
  a real device needs the Mac's LAN address). The Example target gets a local-networking ATS exception
  (`NSAllowsLocalNetworking`); the SDK target gets none.
- Showcase ships to TestFlight, where no dev server exists. It keeps mocks and a "paste sessionId + secret"
  path; the dev-server client is hidden in release builds (`#if DEBUG`).
- **Automated tests use the same server.** A script `scripts/run-dev-e2e.sh` starts the server, waits for
  `/healthz`, runs the real-API test target with `SUNBAY_DEV_SERVER_URL` set, then stops the server. Real-API tests
  skip (not fail) when that variable is absent, so plain `swift test` stays offline and green. They live in a
  separate target from `SunbayCheckoutE2ETests`, and only ever run against `dev`/`test` environments.
- **Warnings that cannot be missed:** (a) the server prints a red banner at startup and in every `/healthz`
  response: "DEV ONLY. This server holds merchant API credentials. In production, create the session in YOUR
  backend; never put the API key in an app."; (b) the same text at the top of `server.mjs`, `Example/README.md`
  and `docs/security-and-pci.md`; (c) the Example screens that use it show a persistent DEV banner naming the
  server URL. (d) `README.md` includes a "production integration" snippet showing the host app fetching
  `{sessionId, checkoutClientSecret, customerAccessSecret?}` from its own backend.

### 5.8 Card-on-file options (host control)

Semantics:
- Session `supportStoreCard` (default `true` when absent) is the merchant-side switch. When `false`, the SDK forces
  COF off: no saved-card list, no "save this card" checkbox, no `card/list` call, `storeCard` never sent.
  The host cannot override a `false` session. "Session wins."
- Submit-body `storeCard` is the real per-payment choice: `true` only if the user ticked the checkbox
  (or it was pre-ticked by the option below and not untouched).

Public API: a new extensible value type on `CheckoutConfiguration`:

```swift
public struct CardOnFileOptions: Sendable, Equatable {
    /// Host switch. Effective COF = session.supportStoreCard && isEnabled && customerAccessSecret != nil.
    public var isEnabled: Bool              // default true
    /// Pre-tick the "save this card" checkbox for new cards.
    public var saveByDefault: Bool          // default false
}
// CheckoutConfiguration gains: public let cardOnFile: CardOnFileOptions   // default CardOnFileOptions()
```

- Struct with defaulted members so later options (for example hiding the checkbox, limiting listed cards) are
  additive, not breaking.
- Single decision point: the Core computes `effectiveCOF` once after the session loads, and both the saved-card
  list and the checkbox read it. The existing decision in `PaymentSheet` (secret present && `session.cofEnabled`)
  and `CheckoutController.listSavedCards` fold into it.
- `saveByDefault` defaults to `false` (my call): a pre-ticked storage consent is a compliance risk in some regions;
  the host opts in explicitly. The user can always untick.
- Update `product-spec.md` §2.1 and the Example/Showcase settings with the two switches.

## 6. Open items needing the backend or user

1. Apple Pay: the API doc says `cardEncryptedData` is used for GOOGLE_PAY and APPLE_PAY. Confirm whether the
   Apple Pay token is sent raw (JSON or base64 of `paymentData`) or encrypted, and the exact `paymentMethod`
   value. Phase 1's Apple Pay exit criterion depends on this.
2. RSA padding (spec §8 item 1): keep PKCS#1 v1.5 as web does; confirm on dev.
3. Whether the dev/test origins above are the right ones for the native SDK, and whether HPP bot protection
   or WAF lets non-browser User-Agents through. A working dev sandbox with a test merchant and
   `checkoutClientSecret` is also needed to verify any phase.
4. Whether `customerAccessSecret` TTL/revocation errors have stable codes to map to user-facing states.


## 7. Left to the builder

File layout inside Core, exact timeout values, header name for SDK identification, retry details,
mapper naming, fixture format, and the privacy-manifest wording (the SDK starts making network
calls, so `PrivacyInfo.xcprivacy` must be added and `security-and-pci.md` updated).
