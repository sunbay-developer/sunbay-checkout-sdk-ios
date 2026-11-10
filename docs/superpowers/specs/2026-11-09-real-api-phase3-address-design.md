# Real API integration, phase 3 (address) — design

Status: approved in conversation (2026-11-09). Short design; extends
`2026-11-09-real-api-integration-design.md` §5.5 phase 3.

## Intent

Addresses the user types are never submitted today, the session's `collect*` flags are ignored, and the
host has no way to hand over an address it collected itself. Saving a card fails with `C01` because no
`payerBillingInfo` is sent. Phase 3 makes address data flow end to end, aligned with the JS SDK, and loads
country lists, field layouts and subdivisions from the HPP address endpoints.

## Semantics (decided by the user, mirroring the JS SDK)

- Session `collectBillingAddress` / `collectShippingAddress`: the order **must** carry that address
  (backend-enforced).
- SDK display (`Appearance.billingAddressMode` / `shippingAddressMode`): whether the SDK **shows** its own
  form. New default `.automatic` follows the session flag (shown as the full form when required, hidden
  otherwise). `.simple` / `.full` force the form on, `.off` forces it off (the host collects the address
  itself). Hiding never relaxes the backend requirement.
- Host-provided address: `PaymentSheet` and `ApplePayButton` accept optional `billingAddress` /
  `shippingAddress`. Per mode, a host value wins over the SDK form value (JS `confirm` merge rule).
- No front-end blocking: if the order needs an address and none is available, the SDK still submits and the
  backend decides (JS `addressAggregator`: "the front end does not overstep").
- Wire mapping: `line1`/`line2` → `address`/`address2`; send `country, state, city, address, address2,
  postalCode, firstName, lastName, phone, email`; `district` is not part of the backend `AddressInfo` and is
  not sent. Empty strings are omitted; an address with no non-empty field is omitted entirely.

## Name fields per address kind (user, 2026-11-09)

As in HPP (`AddressForm` `collectName`: billing `false`, shipping `true`), the shipping form collects first and
last name and the billing form does not. The form component takes an internal options value
(`AddressFormOptions(collectName:)`, defaults `.billing` / `.shipping`) so billing can collect names later, and
further per-form switches (for example phone, which HPP also supports) are additive. Not public yet (my call);
it can be exposed through `Appearance` if merchants need it.

## Linkage scope

This phase: country selection reloads the field layout, subdivisions dropdown and validation pattern from
`GET {hpp}/api/address/country` (`{countries, detectedCountry}`) and `GET {hpp}/api/address/country/{code}`
(`{code, fields, layout, subdivisions}`), with the configured locale. Postal-code → state and Google
autocomplete are later (see checklist; Google needs an HPP proxy because a browser key cannot be used from
apps).

## Approaches

- **Chosen: one sensible way.** Reuse the existing `AddressMetadataService` protocol, cache and full-form UI;
  move `HTTPAddressMetadataService` onto `SunbayAPIClient` (environment host, envelope, `Accept-Language`).
- Rejected: a new public `AddressInfo` type mirroring JS. `AddressInput` is already public and already what
  both forms produce; it gains `phone` and `email` instead (my call: avoids two near-identical public types;
  JS docs call the same shape `AddressInfo`).
- Rejected: falling back to the simple form when metadata fails. The full form already shows an error with a
  retry button, as the web form does, and missing addresses never block payment (my call).

## Constraints

English only; Core stays UIKit-free; addresses are PII: never in logs or analytics, but not secrets
(`SubmitRequest` descriptions already omit them). Public API additions are defaulted (minor bump).

## Verification

`swift test`; simulator UI tests for the mode resolution and form → submit flow; real-API: load country list
and the US config from dev; with the sandbox card, `storeCard: true` plus a billing address no longer returns
`C01` (the dev merchant is expected to answer `F "No available channel"` until its store-card channel is set up).
