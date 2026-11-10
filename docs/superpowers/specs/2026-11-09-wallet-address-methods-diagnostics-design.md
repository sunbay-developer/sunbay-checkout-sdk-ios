# Apple Pay addresses, payment-method model and filter, diagnostics: design

Status: draft for review. Date: 2026-11-09.
Aligned with the JS SDK / HPP work of 2026-11-10 (`checkout/docs/superpowers/specs/2026-11-10-payment-method-model-and-filter-design.md`
and the host-address behavior in `checkout/src/sdk-runtime/hostAddress.ts` / `Orchestrator.ts`).
Related: `2026-11-09-real-api-integration-design.md`, `2026-11-09-real-api-phase3-address-design.md`,
`docs/backend-native-wallet-params.md` (backend request, separate).

## 1. Intent

Three gaps remain after phase 3, and one phase-3 behavior has to be corrected to match the JS SDK:

1. **Apple Pay ignores addresses.** The Apple Pay sheet never asks for billing or shipping contacts and the contacts it
   returns are dropped, so orders that require an address cannot be paid with Apple Pay. HPP and the JS SDK ask the wallet
   for contacts when the session requires them and submit what the wallet returns.
2. **Phase-3 address rules differ from JS.** iOS lets a host-provided address override the form and submits it even when
   the session does not require an address. JS does the opposite (form first; host address only as a gated fallback).
3. **No payment-method model, filter or ordering.** The session's method list is collapsed into a set (order and card
   brands are lost), the home-page layout hard-codes which method is "express", and a host cannot hide or reorder anything.
4. **Diagnostics are silent.** Non-fatal problems (saved-card list failed, session load failed for the Apple Pay button,
   a filter identifier that matches nothing) are swallowed. The host has no way to see them.

## 2. Goals, non-goals, anti-goals

Goals
- Apple Pay requests billing/shipping contacts per session rules, maps the returned contacts to addresses and submits
  them; a complete host-provided address replaces the request for that kind.
- Address resolution for card and wallet is identical to the JS SDK (same definitions of "complete", same precedence,
  same warning codes), plus one iOS rule: with `.automatic`, a usable host address means the SDK form is not shown.
- An internal provider registry (key, kind express/normal, static availability) and a public `PaymentMethodFilter`
  (`hide`, `order`) with the same identifier model as JS (`CARD`, `APPLE_PAY`, raw methods such as `AMEX`).
- One diagnostic channel on the main entry (`SunbayCheckout.onDiagnostic`) for warnings and non-terminal errors.

Non-goals
- Reading `ewalletParam` (networks, capabilities, country) in the Apple Pay request, and any host override of wallet
  payment parameters (the latter is decided: never; network and capability support come from the session). Reading is
  paused pending a decision. The comparison in `docs/backend-native-wallet-params.md` shows native and web can share the
  same `ewalletParam`, with only a case-insensitive network-name lookup on the client; the user had asked for native-specific
  values from the backend per `sessionType`. Until that is decided the Apple Pay request keeps today's hard-coded country,
  networks and capability.
- Google Pay on iOS, Google Places address autocomplete, postal-code to state lookup, the embedded component (L2).
- Mirroring terminal payment failures on the diagnostic channel, and putting warnings on `CheckoutOutcome` (both decided:
  no).

Anti-goals
- Address content, card data, wallet tokens, secrets in any diagnostic payload, log or error message.
- A diagnostic or filter problem changing a payment result or blocking a payment that could otherwise be made.
- Source-breaking changes to public enums beyond what phase 3 already shipped (nothing is released; no tags exist).

## 3. Constraints

English only in code and docs; Core imports no UIKit/PassKit (PassKit conversion lives in the UI-layer wallet file);
public additions are defaulted; the SDK has no release tag yet, so behavior corrections to unreleased phase-3 rules are
allowed (recorded in the checklist for the first release notes).

## 4. Approaches

- **Chosen.** Reuse the JS model: one pure resolution layer for addresses, one for the method filter, one reporter for
  diagnostics, all in Core; UI and wallet code call them.
- Rejected: warnings as part of `CheckoutOutcome` (different lifecycle, breaks exhaustive switches); handlers on each
  component (three components and a future embedded one would each need the same API); a closed Swift enum of method
  ids (cannot express `WECHAT_PAY` or a single brand like `AMEX`); client-side `ewalletParam` processing (paused).

## 5. Design

### 5.1 Address resolution (Core, pure)

Definitions (identical to JS `hostAddress.ts`, except where noted)
- Kind: `billing` or `shipping`. `collect(kind)` is the session flag.
- Host entry: the optional `billingAddress` / `shippingAddress` passed to `PaymentSheet` / `ApplePayButton`. Only
  whitelisted fields are kept and trimmed. `ApplePayButton` additionally exposes settable properties of the same names
  (`nil` clears), read at tap time; `PaymentSheet` takes them at init (one presentation).
- Complete: billing needs `country`, `city`, `line1`, `postalCode`; shipping needs those plus `firstName` and `lastName`
  and `phone`. (JS also accepts `recipientName`; `AddressInput` has no such field and none is added. My call.)
- Usable host entry for a kind: `collect(kind)` and complete. If `collect(kind)` and the entry is incomplete: treated as not
  provided and `ADDRESS_INCOMPLETE` is reported. If `collect(kind)` is false the entry is not submitted and nothing is reported.

Form visibility (replaces phase-3 `resolveAddressMode`)
- `.automatic` (default): the SDK form (full layout) is shown for a kind iff `collect(kind)` and there is no usable host entry.
- `.simple` / `.full`: shown, regardless of session flag or host entry. `.off`: not shown.

Card (new-card submit), per kind
1. Form shown: the form value is used; a host entry that is present is ignored and `ADDRESS_ENTRY_IGNORED` is reported.
2. Form not shown: the usable host entry if any; otherwise none.
"Same as billing" keeps its phase-3 meaning and exists only when a billing form is shown.

Saved-card and wallet submits never have an SDK form; they use the usable host entry (and, for wallets, the contacts below).

Apple Pay, per kind
- Request the contact for a kind iff `collect(kind) && (no usable host entry || a form for that kind is shown in the same
  sheet)`. When `collect(kind)` is false nothing is requested, even if a form is shown (an explicit `.simple` / `.full`
  form on a session that does not require the address). The form lives on another page and cannot be read at tap time, so
  when a form is shown the host entry is ignored for the wallet and `ADDRESS_ENTRY_IGNORED` is reported. Required fields as
  on HPP: billing `post` and `name`; shipping `post`, `name`, `phone`.
- The content view controller knows the resolved form visibility per kind and passes it to a pure Core function
  `walletContactRequest(collect:hostEntry:formShown:)` at tap time. The standalone `ApplePayButton` has no form
  (`formShown` is always false).
- Returned contacts are converted to `AddressInput` (pure function in the PassKit file, testable on the host):
  `isoCountryCode` uppercased to `country`, `state`, `city`, `postalCode`, street lines (first line `line1`, remaining
  lines joined with ", " as `line2`), `givenName`/`familyName`, phone, email. A returned contact wins over a host entry
  for that kind.
- `customerName` is the resolved shipping address name, else the billing name; `customerEmail` is the wallet's shipping
  email, else billing email (HPP does the same). Both are new optional fields on `SubmitRequest`. On the wire they are the
  top-level optional strings `customerName` and `customerEmail` of `SubmitSessionPaymentReq` (see
  `docs/api/checkout-api.json`); they are omitted when unknown and sent on every path when known.

Reporting: `ADDRESS_INCOMPLETE` / `ADDRESS_ENTRY_IGNORED` carry `ignored: ["billingAddress"]` or `["shippingAddress"]`.
Deduplicated per code and identifier. For `ApplePayButton` the properties' setters reset the dedup state for that kind and
evaluate the entry immediately (as JS evaluates on `updateCheckout`); the same evaluation runs again at tap time and the
dedup prevents repeats.

Form options (internal): `AddressFormOptions` gains `collectPhone`; billing `(name: false, phone: false)`, shipping
`(name: true, phone: true)` as on HPP (`showPhone`, `collectName`). The simple and full forms render and return the phone.

### 5.2 Apple Pay request (WalletAuthorizer)

- `WalletAuthorizing.authorize` takes a contact request (`billing: Bool`, `shipping: Bool`) and the merchant name; the
  `confirm` callback receives a value with the token `Data`, the optional billing and shipping addresses and the optional
  email instead of bare `Data`. The summary item label becomes the merchant name (fallback "Total").
- Country, networks and capabilities stay hard-coded (see non-goals). A follow-up reads them from `ewalletParam` once the
  decision above is made; this design does not.
- The controller's wallet confirm merges addresses per 5.1 and passes them on.

### 5.3 Provider registry and payment-method filter

- Session model: keep the ordered list of backend methods and an ordered `cardBrands` list (all `type = CARD` entries:
  method, name, logo URL); `methods: Set<PaymentMethodKind>` stays for compatibility.
- Internal registry: `CARD` (normal, always available) and `APPLE_PAY` (express, available when the device can pay and a
  merchant id exists). The home page renders groups from the registry; `expressPosition` still places the express group
  above or below the normal group, and `.off` hides it.
- Public: `PaymentMethodID` (string-backed, `ExpressibleByStringLiteral`, constants `.card` = `"CARD"`, `.applePay` =
  `"APPLE_PAY"`), `PaymentMethodFilter(hide:order:)`, `CheckoutConfiguration.paymentMethodFilter` (default empty).
- Semantics = JS model layer: an identifier matches by logical key first (`CARD` covers every `type = CARD` entry), then by
  raw method (`AMEX`); case-sensitive; no aliases; `hide` wins over `order`; `order` is stable and unlisted items keep their
  order after listed ones; a filter can only reduce or reorder. An identifier that matches nothing is ignored and
  `PAYMENT_METHOD_FILTER_IGNORED` is reported with `ignored: [identifier]` and a reason that lists the available
  identifiers.
- `order` acts within a group only (express group, normal group) and never moves a group; only `expressPosition` places
  the express group. Today each group has one member, so `hide` is the only
  visible effect until another method is registered.
- The raw session stays in the controller; the filter is applied where the UI and `ApplePayButton` read availability, so
  submit never depends on it. `hide: ["APPLE_PAY"]` hides the sheet row and makes the standalone button unavailable.
- `hide: ["CARD"]` hides the new-card row and the saved cards (they are card payments), keeps Apple Pay, and skips the
  saved-card list request. Saved cards are otherwise governed by `CardOnFileOptions`. (My call.)
- A provider is available iff the session contains a matching entry (as on HPP: `CARD` needs at least one `type = CARD`
  entry, `APPLE_PAY` needs an `APPLE_PAY` entry), its static check passes, and the filter did not hide it. This is
  evaluated once after the session is loaded and before any UI is shown. Today's home page shows the new-card row even
  when the session has no card entry; that changes to HPP parity (real sessions always list card brands). Saved cards
  count as payable only when `CARD` is available. (My call.)
- If no provider is available, `present` returns `.failed` with `CheckoutError` code `NO_PAYMENT_METHOD_AVAILABLE`,
  category `.configuration`, and no UI is shown. (My call.)
- Single-brand identifiers are accepted and filter `cardBrands`; no UI uses brand icons yet, so there is no visible effect
  in this version. (My call.)

### 5.4 Diagnostics on the main entry

```swift
public enum CheckoutDiagnostic: Sendable {
    case warning(CheckoutWarning)
    case error(CheckoutError, sessionId: String?)   // non-terminal only
}
public struct CheckoutWarning: Sendable, Equatable {
    public let code: Code                 // string-backed: paymentMethodFilterIgnored, addressIncomplete, addressEntryIgnored
    public let ignored: [String]
    public let reason: String
    public let sessionId: String?
}
// SunbayCheckout:
public var onDiagnostic: ((CheckoutDiagnostic) -> Void)?   // delivered on the main thread
```
- Codes are the iOS subset of the cross-platform `WARNING_CODES`: `PAYMENT_METHOD_FILTER_IGNORED`, `ADDRESS_INCOMPLETE`,
  `ADDRESS_ENTRY_IGNORED`. `EXPRESS_OPTION_IGNORED` does not apply (options are enums). `WALLET_PARAMS_INVALID` is not added.
- Non-terminal errors that become `.error`: saved-card list failure (degraded), address-metadata load failure, session load
  failure for the standalone Apple Pay button. They carry code, category and trace id only.
- A Core `DiagnosticsReporter` owns deduplication (same code and identifier once) and a buffer (cap 50) that is replayed
  when `onDiagnostic` is first assigned, like JS's replay on first `on('warning')`. `PaymentSheet`, `ApplePayButton` and
  the future embedded component report through it; the reporter is created with `SunbayCheckout`.
- Terminal results stay only on `CheckoutOutcome` / `onResult`. Warnings never change a result.
- Payloads never contain address values, card data, tokens or secrets.

### 5.5 Public API summary

Added: `PaymentMethodID`, `PaymentMethodFilter`, `CheckoutConfiguration.paymentMethodFilter`, `SunbayCheckout.onDiagnostic`,
`CheckoutDiagnostic`, `CheckoutWarning`, `ApplePayButton.billingAddress` / `.shippingAddress`.
Behavior corrected relative to unreleased phase 3: host addresses are submitted only when the session requires that kind
and the entry is complete; form value beats host entry; `.automatic` hides the form when a usable host entry exists.
Internal changes: `WalletAuthorizing`, `SubmitRequest` (public struct, new optional fields `customerName`, `customerEmail`).

### 5.6 Verification

- Host tests (pure): completeness, usable-entry rule, form visibility, card and wallet resolution tables, contact conversion,
  filter matching/ordering/ignored/idempotence, reporter dedup/buffer/replay, wire body for new fields.
- Simulator tests: `.automatic` with and without a usable host entry, explicit modes with an entry (warning), Apple Pay row
  hidden by the filter, group order, empty-result failure.
- Not verifiable here: the Apple Pay sheet requesting contacts and returning them on a real device, token acceptance by the
  backend, visual layout. These go to the checklist.

## 6. Open items

1. Backend (separate document `docs/backend-native-wallet-params.md`): `countryCode` in `ewalletParam`, Google Pay
   `environment` per environment, Apple Pay merchant id and certificate onboarding, token format confirmation. Decision
   pending on whether native shares the web `ewalletParam` as is.
2. Cross-platform: Android needs the same address rules and warning codes; the JS `WARNING_CODES` registry is the shared list.

## 7. Left to the builder

File and type placement inside Core and the UI layer, the exact `Code` representation, buffer data structure, reason text,
localization of the "NO_PAYMENT_METHOD_AVAILABLE" user-facing message (Core error only; no new UI copy is required because
the sheet is not shown), and the order of implementation tasks.
