# Real API Integration, Phase 3 (address) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Billing and shipping addresses flow end to end: shown per session and host settings, loaded dynamically from HPP, merged with host-provided addresses, and submitted as `payerBillingInfo` / `payerShippingAddress`.

**Architecture:** Core gains the session `collect*` flags, two optional addresses on `SubmitRequest` and a merge rule in `CheckoutController` (host value wins per mode). `SunbayAPIClient` gains GET with query items so `HTTPAddressMetadataService` uses the environment host and envelope; it becomes the default address service. The UI resolves the new `.automatic` mode against the session and passes form values into the confirm action.

**Tech Stack:** Swift 5.9, URLSession, UIKit, XCTest (host + iOS simulator), Tuist Example, Node dev server.

**Spec:** `docs/superpowers/specs/2026-11-09-real-api-phase3-address-design.md` (parent: `2026-11-09-real-api-integration-design.md`). Contracts: `docs/api/checkout-api.json` (`AddressInfo`, `SubmitSessionPaymentReq`, `LoadSessionResp`); live HPP address responses below.

## Global Constraints

- English only; Core imports no UIKit/PassKit; iOS 15; public API additions defaulted.
- Addresses are PII: never logged, never in error messages or analytics; `SubmitRequest` descriptions keep omitting them.
- Wire `AddressInfo` keys: `country, state, city, address, address2, postalCode, firstName, lastName, phone, email` (`line1` → `address`, `line2` → `address2`); `district` is not sent; empty or whitespace-only values are omitted; an address with no remaining field is omitted entirely.
- Merge rule per mode: host-provided address ?? SDK form address. The SDK never blocks a submit because an address is missing.
- `.automatic` (new default for both modes): session `collectX == true` → `.full`, else `.off`. `.simple` / `.full` / `.off` are explicit host choices and ignore the session flag.
- Live HPP (dev, 2026-11-09): `GET /api/address/country?locale=en-US` → envelope `data: {countries: [{code, name}] (16), detectedCountry}`; `GET /api/address/country/US?locale=en-US` → `data: {code, fields: {<type>: {type, required, pattern?, label, placeholder}}, layout: [[type]], subdivisions: [{code, name}]}`.
- Address metadata failures never block payment (form shows its existing error + retry).
- Branch `feature/real-api-phase3-address`; commits with exact files only; never `git add .`, never `git add -f`, never push. Simulator `id=D8302CDE-6AD6-4593-9A11-6F7BC3C9DB57`.

## Review Focus

1. Host passes only `billingAddress` while the form shows shipping with "same as billing" on: the host billing replaces billing only; shipping is the form's resolved shipping (with "same as billing" on, that is the form billing). Pinned by a Task 1 test.
2. `.automatic` with `collectBillingAddress: true` but the metadata request fails: the error + retry state shows; Pay still submits without `payerBillingInfo`.
3. An address whose fields are all empty strings (user opened the form, typed nothing) is omitted from the submit body, not sent as `{}`.
4. The full form and the country list use the configured `CheckoutConfiguration.locale` (not nil) for `Accept-Language` and the `locale` query.
5. Session JSON without `collectBillingAddress` / `collectShippingAddress` decodes as `false` for both.

---

### Task 1: Core address submit path

**Files:**
- Modify: `Sources/SunbayCheckout/Core/AddressMetadata/AddressMetadataModels.swift` (`AddressInput` gains `phone: String?`, `email: String?`, defaulted in init), `Core/Models/CheckoutSession.swift` (`collectBillingAddress: Bool`, `collectShippingAddress: Bool`, init params defaulted `false`), `Core/ContractDecoding.swift` (decode both flags, absent → false), `Core/PaymentService.swift` (`SubmitRequest` gains `billingAddress: AddressInput?`, `shippingAddress: AddressInput?`, defaulted nil, still redacted), `Core/Network/HTTPPaymentService.swift` (wire encoding), `Core/CheckoutController.swift`
- Test: `Tests/SunbayCheckoutTests/Core/ContractCodableTests.swift`, `HTTPPaymentServiceTests.swift`, `CheckoutControllerTests.swift`

**Interfaces:**
- Produces:
  - `struct AddressInfoWire: Encodable, Sendable` (internal) with `static func make(_ input: AddressInput?) -> AddressInfoWire?` implementing the Global Constraints mapping (trim, omit empty, nil when nothing left).
  - `CheckoutController.start(sessionId:customerAccessSecret:checkoutClientSecret:billingAddress: AddressInput? = nil, shippingAddress: AddressInput? = nil)`; host addresses are stored per start (reset at the top of `start`).
  - `CheckoutController.confirmNewCard(_:save:billingAddress: AddressInput? = nil, shippingAddress: AddressInput? = nil)` (form values); `confirmSavedCard` and `confirmWallet` send host addresses only.
  - Every submit uses `billing = hostBilling ?? formBilling`, `shipping = hostShipping ?? formShipping`.

- [ ] **Step 1: Failing tests.** Codable: session JSON with `"collectBillingAddress": true, "collectShippingAddress": false` maps to the two flags; without them both `false`. HTTPPaymentService: a CARD submit with `billingAddress: AddressInput(country:"US", line1:"1 Main St", line2:" ", city:"San Jose", state:"CA", postalCode:"95112", district:"X", firstName:"A", lastName:"B", phone:"1", email:"a@b.c")` sends `payerBillingInfo == {"country":"US","address":"1 Main St","city":"San Jose","state":"CA","postalCode":"95112","firstName":"A","lastName":"B","phone":"1","email":"a@b.c"}` (no `address2`, no `district`, no `line1`); `AddressInput(country:"", line1:"  ")` → no `payerBillingInfo` key; shipping maps to `payerShippingAddress`. Controller: host billing H + form billing F → submitted billing H; host nil + form F → F; host shipping nil + form shipping S → S while host billing H is used for billing (Review Focus 1); saved-card and wallet submits carry the host addresses; a second `start` without host addresses clears the previous ones; `String(reflecting:)` of a request with addresses contains neither `1 Main St` nor `a@b.c`.
- [ ] **Step 2:** `swift test --filter 'ContractCodableTests|HTTPPaymentServiceTests|CheckoutControllerTests'` → FAIL.
- [ ] **Step 3: Implement** the interface block.
- [ ] **Step 4:** Same filter, then full `swift test` → 0 failures.
- [ ] **Step 5: Commit**: `feat(address): submit billing and shipping addresses with host-over-form merge`.

---

### Task 2: Real address metadata adapter by default

**Files:**
- Modify: `Sources/SunbayCheckout/Core/Network/SunbayAPIClient.swift` (add `get<Response: Decodable & Sendable>(_ route: SunbayEndpoints.Route, query: [URLQueryItem] = [], timeout: TimeInterval = 15) async throws -> Response`, same envelope/error mapping as `post`, idempotent so it may retry once on a transport error), `Core/Network/SunbayEndpoints.swift` (routes `.addressCountries`, `.addressCountryConfig(code: String)` → `/api/address/country`, `/api/address/country/{code}` with the code percent-encoded), `Core/AddressMetadata/HTTPAddressMetadataService.swift` (now `init(client: SunbayAPIClient)`; drop the raw `baseURL`/URLSession path; keep the DTOs), `Public/SunbayCheckout.swift` (default init wraps `HTTPAddressMetadataService(client:)` in `AddressMetadataCache`; the injecting init keeps `EmptyAddressMetadataService` when nil)
- Test: `Tests/SunbayCheckoutTests/Core/SunbayAPIClientTests.swift`, `SunbayEndpointsTests.swift`, `Tests/SunbayCheckoutTests/Core/HTTPAddressMetadataServiceTests.swift` (new or replacing any existing one), `Tests/SunbayCheckoutTests/Public/SunbayCheckoutDefaultWiringTests.swift`

**Interfaces:**
- Consumes: `SunbayAPIClient`, `AddressMetadataService.countries(locale:)` / `countryConfig(countryCode:locale:)` (unchanged protocol).
- Produces: `HTTPAddressMetadataService(client:)`; `SunbayAPIClient.get(_:query:timeout:)`; routes above.

- [ ] **Step 1: Failing tests.** Endpoints: `.addressCountries` on `.dev` → `https://checkout.sunbay-dev.com/api/address/country`; `.addressCountryConfig(code: "U/S")` encodes as one path component. Client GET: method `GET`, no body, query `locale=zh-CN`, envelope decode, `code != "0"` → `.payment`, 5xx → `.network`. Adapter (stub, live-shaped JSON from the Global Constraints): countries list maps 2 entries + `detectedCountry "US"`; US config maps `layout` rows to `[[.firstName, .lastName], [.country], [.line1], [.line2], [.city], [.state, .postalCode]]`, `fields[.postalCode].pattern` kept, unknown field types skipped, subdivisions mapped; the `locale` query item is sent when non-nil and absent when nil. Default wiring: the default checkout's address service, asked for countries, hits `/api/address/country` on the dev host through the injected stub session.
- [ ] **Step 2:** Focused `swift test --filter` on those suites → FAIL.
- [ ] **Step 3: Implement.**
- [ ] **Step 4:** Focused filter, full `swift test`, `swift build` → green.
- [ ] **Step 5: Commit**: `feat(address): load address metadata from HPP through the API client by default`.

---

### Task 3: UI mode resolution, form values to confirm, host parameters

**Files:**
- Modify: `Sources/SunbayCheckout/Public/Appearance.swift` (`AddressCollectionMode.automatic`, new default for both modes, documented), `UI/PaymentSheet/PaymentSheet.swift` (public init gains `billingAddress: AddressInput? = nil, shippingAddress: AddressInput? = nil`; passes them to `controller.start`; resolves modes from the loaded session; `UserAction.confirmNewCard(CardInput, save: Bool, billing: AddressInput?, shipping: AddressInput?)`), `UI/Content/CheckoutContentViewController.swift` (takes resolved modes and the configured locale; collects `addressInput` from the billing view and, unless "same as billing" is on, from the shipping view; same-as-billing → shipping = form billing; passes `locale` to `DynamicAddressFormView`), `UI/Wallet/ApplePayButton.swift` (public init gains the two optional addresses, passed to `start`)
- Test: `Tests/SunbayCheckoutTests/UI/CheckoutContentViewControllerTests.swift`, `PaymentSheetRunCheckoutTests.swift`, `Tests/SunbayCheckoutTests/Public/AppearanceTests.swift` (or the existing appearance test file)

**Interfaces:**
- Consumes: Task 1 controller signatures; `CheckoutSession.collectBillingAddress/collectShippingAddress`.
- Produces: `static func resolveAddressMode(_ mode: Appearance.AddressCollectionMode, collect: Bool) -> Appearance.AddressCollectionMode` (internal, in `Content` or `Theme`; `.automatic` → `collect ? .full : .off`, others unchanged); test seams on the content VC if missing: `isBillingFormVisibleForTest`, `isShippingFormVisibleForTest`, `setSameAsBillingForTest(_:)`.

- [ ] **Step 1: Failing tests** (host `swift test` for `resolveAddressMode` and the `Appearance` default; simulator for the rest): `resolveAddressMode(.automatic, collect: true) == .full`, `(.automatic, false) == .off`, `(.simple, false) == .simple`, `(.off, true) == .off`; `Appearance().billingAddressMode == .automatic`. Content VC: session `collectBilling: true, collectShipping: false`, default appearance → billing form visible, shipping hidden; explicit `.off` billing with `collectBilling: true` → hidden; simple billing form filled (country US, line1, postal) then Pay → delegate gets `.confirmNewCard(_, save:, billing: <those values>, shipping: <same values>)` when same-as-billing is on, and `shipping: nil` when the shipping section is off. PaymentSheet run: host `billingAddress` reaches the controller (the stub payment service's last submit carries it) even when the billing form is `.off`.
- [ ] **Step 2:** `swift test --filter` for the host tests and `xcodebuild test -scheme SunbayCheckout-Package -destination 'id=D8302CDE-6AD6-4593-9A11-6F7BC3C9DB57' -only-testing:SunbayCheckoutTests/CheckoutContentViewControllerTests -only-testing:SunbayCheckoutTests/PaymentSheetRunCheckoutTests` → FAIL.
- [ ] **Step 3: Implement** the interface block; update existing tests that assumed the `.simple` default (pass `.simple` explicitly where they need the simple form).
- [ ] **Step 4:** Focused simulator run, full simulator suite once, full `swift test` → 0 failures.
- [ ] **Step 5: Commit**: `feat(address): follow session collect flags by default and accept host addresses`.

---

### Task 4: Example, real-API checks, docs

**Files:**
- Modify: `Example/SunbayCheckoutDemo/Sources/DemoSettings.swift`, `DemoRootView.swift` (address pickers gain "Automatic (follow session)" as default; separate "Order requires billing/shipping" toggles sent to the dev server as `collectBillingAddress` / `collectShippingAddress`; optional "Pass a host billing address" toggle that sets a fixed US test address on `PaymentSheet(billingAddress:)`), `Tests/SunbayCheckoutRealAPITests/` (new `RealAPIAddressTests.swift`), `docs/product-spec.md` (§2.1 address modes + host addresses; §7.3 address mapping), `docs/real-api-integration-checklist.md`, `Example/README.md`

**Interfaces:**
- Consumes: Tasks 1-3.

- [ ] **Step 1: Real-API tests** (skip rules as before): (a) `HTTPAddressMetadataService` on dev returns ≥ 1 country and the US config has a `state` field with ≥ 50 subdivisions; (b) with `SUNBAY_TEST_CARD_*` set: new dev session, new-card submit with `save: true` and a host billing address → the outcome is not a failure with code `C01` (record the actual outcome: expected `failed` with `"No available channel"` on the dev merchant, or `succeeded`); report the observed result rather than asserting a specific success. Run `scripts/run-dev-e2e.sh` without the card env; the controller reruns it with the card.
- [ ] **Step 2: Example** changes above; `tuist generate --no-open` in `Example/SunbayCheckoutDemo`; simulator build → BUILD SUCCEEDED.
- [ ] **Step 3: Docs (English):** product-spec §2.1 (`.automatic`, `.simple`/`.full`/`.off`, `PaymentSheet`/`ApplePayButton` `billingAddress:`/`shippingAddress:`, merge rule, no front-end blocking) and §7.3 (`payerBillingInfo`/`payerShippingAddress` mapping); checklist: tick address metadata live and address submit; keep open "postal code → state" and "Google autocomplete needs an HPP proxy (browser key cannot be used from apps; options: HPP proxy recommended, Places SDK per-bundle keys, MapKit)"; update the C01 entry with the observed result. Example README: the new toggles.
- [ ] **Step 4:** Full `swift test` → 0 failures.
- [ ] **Step 5: Commit**: `test(address): real-API address checks, Example address options and docs`.

---

## Self-review notes

- Spec coverage: semantics (Tasks 1, 3), linkage via HPP metadata (Task 2, plus existing full form), host addresses (Tasks 1, 3), wire mapping (Task 1), no blocking (Tasks 1, 3), verification incl. C01 (Task 4).
- Names: `AddressInfoWire.make`, `start(...billingAddress:shippingAddress:)`, `confirmNewCard(_:save:billingAddress:shippingAddress:)`, `UserAction.confirmNewCard(_, save:, billing:, shipping:)`, `resolveAddressMode(_:collect:)`, `HTTPAddressMetadataService(client:)`, `SunbayAPIClient.get(_:query:timeout:)`, routes `.addressCountries` / `.addressCountryConfig(code:)`.
- Review Focus 1 answer is fixed in the plan text and pinned by a Task 1 test.
