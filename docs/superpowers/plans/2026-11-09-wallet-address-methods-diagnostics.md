# Apple Pay addresses, payment-method model and filter, diagnostics: Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Apple Pay requests and uses billing/shipping contacts and `ewalletParam`; address resolution matches the JS SDK; hosts can filter and order payment methods; non-fatal problems reach the host through `SunbayCheckout.onDiagnostic`.

**Architecture:** Pure Core modules (`DiagnosticsReporter`, `AddressRules`, `PaymentMethodModel`, `PaymentProviderRegistry`, `ApplePayParams`) hold all decisions. `CheckoutController` applies the address rules at confirm time and reports through the reporter. The UI layer resolves form visibility and provider availability with those modules and builds the `PKPaymentRequest`; PassKit conversions are pure static functions in `WalletAuthorizerPassKit.swift`.

**Tech Stack:** Swift 5.9, PassKit, UIKit, XCTest (host `swift test` and iOS simulator `xcodebuild test`), Tuist Example.

**Spec:** `docs/superpowers/specs/2026-11-09-wallet-address-methods-diagnostics-design.md` (sections 5.1-5.6). Backend note: `docs/backend-native-wallet-params.md`. JS references: `checkout/src/sdk-runtime/hostAddress.ts`, `Orchestrator.ts`.

## Global Constraints

- English only; Core imports no UIKit/PassKit; iOS 15; public additions defaulted. Simulator `id=D8302CDE-6AD6-4593-9A11-6F7BC3C9DB57`.
- Address values, card data, tokens and secrets never appear in diagnostics, errors, logs, test failure messages or descriptions.
- Warning codes (raw strings): `PAYMENT_METHOD_FILTER_IGNORED`, `ADDRESS_INCOMPLETE`, `ADDRESS_ENTRY_IGNORED`, `WALLET_PARAMS_INVALID`. A warning is deduplicated per code plus identifiers; it never changes a payment result.
- Address identifiers in warnings: `"billingAddress"`, `"shippingAddress"`.
- "Complete": billing needs non-blank `country`, `city`, `line1`, `postalCode`; shipping needs those plus `firstName`, `lastName` and `phone`. "Usable host entry" for a kind: session `collect(kind)` is true and the sanitized entry is complete. If `collect(kind)` and the entry is present but incomplete: not used, `ADDRESS_INCOMPLETE`. If `collect(kind)` is false: not used, no warning.
- "Draft" (a form value that counts): sanitized form value with at least one non-blank field other than `country`.
- Card, per kind: a draft wins and, if a host entry is present, `ADDRESS_ENTRY_IGNORED`; otherwise the usable host entry. Wallet, per kind: the wallet's returned address; else (no form shown for the kind) the usable host entry; a form shown for the kind means the host entry is ignored for the wallet and `ADDRESS_ENTRY_IGNORED` is reported. Saved card: usable host entries only.
- Apple Pay requests a contact for a kind iff `collect(kind) && (no usable host entry || a form for the kind is shown)`. Fields: billing `postalAddress`, `name`; shipping `postalAddress`, `name`, `phoneNumber`.
- `.automatic` shows a full form for a kind iff `collect(kind)` and there is no usable host entry; `.simple`/`.full` always show; `.off` never.
- Apple Pay request: `countryCode` = non-blank backend value uppercased, else `US`; networks matched case-insensitively to PassKit constants, unknown dropped, duplicates removed; capabilities `supports3DS`/`supportsEMV`/`supportsCredit`/`supportsDebit` mapped, unknown dropped; summary label = merchant name, else "Total". Apple Pay is unavailable (hidden, `WALLET_PARAMS_INVALID` with the missing field names `supportedNetworks` and/or `merchantCapabilities`) when either list is empty after mapping or `ewalletParam` is absent. No other key is read.
- Filter identifiers are case-sensitive: logical key first (`CARD` = every `type = CARD` entry), then raw method (for example `AMEX`). `hide` wins over `order`; `order` is stable, unlisted items keep their order after listed ones; `order` never moves a group. An identifier that matches nothing is ignored with `PAYMENT_METHOD_FILTER_IGNORED`.
- `hide: ["CARD"]` hides the new-card row and saved cards and skips the saved-card list request; Apple Pay stays. A provider is available iff the session has a matching entry, its static check passes and the filter did not hide it; if none is available `present` returns `.failed` code `NO_PAYMENT_METHOD_AVAILABLE`, category `.configuration`, before any UI.
- Diagnostics are delivered on the main thread; events raised before `onDiagnostic` is assigned are buffered (cap 50, oldest dropped) and replayed in order on first assignment. Terminal failures are never mirrored there; warnings never go on `CheckoutOutcome`.
- Branch `feature/wallet-address-methods-diagnostics`; commits with exact files only; never `git add .`, never `git add -f`, never push. Do not read `.env.local` files.

## Review Focus

1. Host entry present, explicit `.simple` form shown, session `collect*` false: no wallet contact requested, the host entry is not submitted, the card submit uses the draft (if any); `ADDRESS_ENTRY_IGNORED` once.
2. Apple Pay returns a shipping contact without phone or name, or a billing contact with no postal address: submitted as returned, no crash, `customerName` falls back, `customerEmail` nil when absent.
3. `ewalletParam` malformed (invalid JSON string, wrong types, empty arrays, absent): the session still decodes, Apple Pay is hidden, exactly one `WALLET_PARAMS_INVALID`.
4. Filter oddities (non-existent id, lowercase `applePay`, empty string, duplicates, same id in `hide` and `order`, everything hidden): never throws or crashes, `hide` wins, one warning per identifier.
5. Diagnostics: handler assigned after events, replaced while events flow, more than 50 buffered events, events raised from the controller actor: all delivered on the main thread, in order, none duplicated.

---

### Task 1: Diagnostics channel

**Files:**
- Create: `Sources/SunbayCheckout/Public/CheckoutDiagnostic.swift`, `Sources/SunbayCheckout/Core/DiagnosticsReporter.swift`, `Sources/SunbayCheckout/Core/AddressMetadata/ReportingAddressMetadataService.swift`
- Modify: `Sources/SunbayCheckout/Public/SunbayCheckout.swift`, `Sources/SunbayCheckout/Core/CheckoutController.swift`, `Sources/SunbayCheckout/UI/Wallet/ApplePayButton.swift`
- Test: `Tests/SunbayCheckoutTests/Core/DiagnosticsReporterTests.swift`, `Tests/SunbayCheckoutTests/Core/CheckoutControllerTests.swift`, `Tests/SunbayCheckoutTests/Public/SunbayCheckoutDiagnosticsTests.swift`, `Tests/SunbayCheckoutTests/Core/AddressMetadataCacheTests.swift` (reporting decorator cases)

**Interfaces:**
- Produces:
  - `public struct CheckoutWarning: Sendable, Equatable { public struct Code: RawRepresentable, Hashable, Sendable, ExpressibleByStringLiteral { public let rawValue: String; ...; public static let paymentMethodFilterIgnored, addressIncomplete, addressEntryIgnored, walletParamsInvalid }; public let code: Code; public let ignored: [String]; public let reason: String; public let sessionId: String? }`
  - `public enum CheckoutDiagnostic: Sendable, Equatable { case warning(CheckoutWarning); case error(CheckoutError, sessionId: String?) }`
  - `final class DiagnosticsReporter: @unchecked Sendable { init(maxBuffered: Int = 50); var handler: ((CheckoutDiagnostic) -> Void)? { get set }; func warning(_ code: CheckoutWarning.Code, ignored: [String], reason: String, sessionId: String?); func error(_ error: CheckoutError, sessionId: String?); func resetWarnings(containing identifier: String) }`. Dedup key for warnings `"<code>:<ignored sorted, comma joined>"`; for errors `"<code>:<sessionId ?? "-">"`. Delivery always via `DispatchQueue.main.async`; `NSLock` guards state.
  - `SunbayCheckout.diagnostics: DiagnosticsReporter` (internal, created in every init) and `public var onDiagnostic: ((CheckoutDiagnostic) -> Void)? { get set }` forwarding to `diagnostics.handler`.
  - `CheckoutController.init(..., reporter: DiagnosticsReporter? = nil)`; `makeController` passes `diagnostics`.
  - `ReportingAddressMetadataService(wrapping: any AddressMetadataService, reporter: DiagnosticsReporter)`: rethrows every error and reports `.error(CheckoutError, sessionId: nil)` (a `CheckoutError` as thrown; any other error mapped to code `ADDRESS_METADATA_FAILED`, category `.network`, fixed message). The default `SunbayCheckout` init wraps the HTTP adapter with it (inside the cache wrapper's inner side).
  - Non-terminal errors reported: `listSavedCards` failure (controller), standalone `ApplePayButton` session-load failure.

- [ ] **Step 1: Failing tests.** Reporter: warning delivered on the main thread (use an expectation, assert `Thread.isMainThread`); same code+ignored twice delivers once; different ignored delivers both; `resetWarnings(containing: "billingAddress")` allows the next one; handler assigned after 3 buffered events replays them in order and then clears the buffer; 60 events before assignment replays the last 50; replacing the handler stops delivery to the old one; errors dedup per code+sessionId; ordering across interleaved warnings and errors is preserved; payload equality. Controller: a failing `CofService` makes `listSavedCards()` return `[]` AND deliver one `.error` carrying the thrown `CheckoutError` code and the session id, and `[]` is still returned. Public: `SunbayCheckout(configuration:).onDiagnostic` set before `diagnostics.warning(...)` receives it; set after replays it. Decorator: success passes through untouched; a throwing inner service rethrows the same error and reports exactly one `.error`.
- [ ] **Step 2:** `swift test --filter 'DiagnosticsReporterTests|CheckoutControllerTests|SunbayCheckoutDiagnosticsTests|AddressMetadataCacheTests'` → FAIL (types missing).
- [ ] **Step 3: Implement** the interface block; wire the reporter into `SunbayCheckout`, `CheckoutController` and the standalone `ApplePayButton` (its session-load `catch` reports `.error` before setting `backendAllowed = false`).
- [ ] **Step 4:** same filter, then full `swift test` → 0 failures.
- [ ] **Step 5: Commit**: `feat(diagnostics): add SunbayCheckout.onDiagnostic with warnings and non-terminal errors`.

---

### Task 2: Address rules in Core and submit fields

**Files:**
- Create: `Sources/SunbayCheckout/Core/AddressRules.swift`
- Modify: `Sources/SunbayCheckout/Core/CheckoutController.swift`, `Sources/SunbayCheckout/Core/PaymentService.swift` (`SubmitRequest` gains `customerName: String?`, `customerEmail: String?`, defaulted nil, still redacted), `Sources/SunbayCheckout/Core/Network/HTTPPaymentService.swift` (`SubmitBody` keys `customerName`, `customerEmail`, omitted when nil)
- Test: `Tests/SunbayCheckoutTests/Core/AddressRulesTests.swift`, `CheckoutControllerTests.swift`, `HTTPPaymentServiceTests.swift`

**Interfaces:**
- Produces:
  - `enum AddressKind: String, Sendable { case billing, shipping; var identifier: String { "\(rawValue)Address" } }`
  - `struct WalletContactRequest: Equatable, Sendable { var billing: Bool; var shipping: Bool }` and `struct WalletAuthorization: Sendable { let token: Data; let billing: AddressInput?; let shipping: AddressInput?; let email: String? }`
  - `enum AddressRules { static func sanitize(_ a: AddressInput?) -> AddressInput?` (trim every field; blank becomes nil; nil when nothing non-blank)`; static func isComplete(_ kind: AddressKind, _ a: AddressInput?) -> Bool; static func hasDraftContent(_ a: AddressInput?) -> Bool` (any non-blank field other than `country`)`; static func customerName(billing: AddressInput?, shipping: AddressInput?) -> String? }` (`"first last"` of shipping when both names non-blank, else of billing, else nil)
  - `CheckoutController`: `start(...)` stores `AddressRules.sanitize(billingAddress/shippingAddress)` (replacing `hostBillingAddress`/`hostShippingAddress` semantics); `func updateHostAddresses(billing: AddressInput?, shipping: AddressInput?)`; `func usableHostEntry(_ kind: AddressKind) -> AddressInput?`; `func evaluateHostEntries(billingFormShown: Bool, shippingFormShown: Bool)` (reports `ADDRESS_INCOMPLETE` and `ADDRESS_ENTRY_IGNORED`); `func walletContactRequest(billingFormShown: Bool, shippingFormShown: Bool) -> WalletContactRequest`.
  - New confirm signatures: `confirmNewCard(_:save:billingAddress:shippingAddress:billingFormShown: Bool = false, shippingFormShown: Bool = false)` (form values; `formShown` says a form existed for the kind), `confirmSavedCard(paymentMethodId:)` (usable host entries only), `confirmWallet(_ authorization: WalletAuthorization, billingFormShown: Bool = false, shippingFormShown: Bool = false)`. The old `confirmWallet(token:)` is removed.
  - Submitted `customerName` = `AddressRules.customerName` of the resolved addresses; `customerEmail` = `authorization.email` (wallet only).
  - The reporter (Task 1) receives warnings with `sessionId`; `dismiss()` and `start` reset the dedup state for both identifiers.

- [ ] **Step 1: Failing tests.** `AddressRulesTests`: sanitize trims, drops blanks, returns nil for all-blank and for nil; billing complete/incomplete table (each of the four fields missing or whitespace-only); shipping needs names and phone (missing last name, missing phone each fail); `hasDraftContent` false for `country`-only, true with `postalCode`; `customerName` prefers shipping, falls back to billing, nil when names partial. Controller (stub `PaymentService` capturing the request; reporter capturing diagnostics): session `collectBilling:false` + complete host billing → request carries no `billingAddress`, no warning; `collectBilling:true` + incomplete entry → no address and one `ADDRESS_INCOMPLETE`; `collectBilling:true` + complete entry, card path, no form → entry submitted; card with a draft and an entry → draft submitted and one `ADDRESS_ENTRY_IGNORED`; card with `country`-only form value and a usable entry → entry submitted; saved-card path → usable entries; wallet path: wallet billing wins over entry, no wallet shipping and `shippingFormShown:false` + usable entry → entry, `shippingFormShown:true` → none plus `ADDRESS_ENTRY_IGNORED`; `walletContactRequest` table for (collect, entry usable/absent/incomplete, formShown) including the formula `collect && (no usable entry || formShown)`; `customerName`/`customerEmail` in the request; a second `start` clears entries and dedup. HTTP: body has `customerName`/`customerEmail` only when set; `SubmitRequest` description still omits addresses and the new fields.
- [ ] **Step 2:** `swift test --filter 'AddressRulesTests|CheckoutControllerTests|HTTPPaymentServiceTests'` → FAIL.
- [ ] **Step 3: Implement.** Update existing controller tests that used the phase-3 "host wins" rules to the new rules.
- [ ] **Step 4:** same filter, then full `swift test`.
- [ ] **Step 5: Commit**: `feat(address): resolve card and wallet addresses with the JS rules and submit customer name and email`.

---

### Task 3: Address UI: form visibility, phone, host entries

**Files:**
- Modify: `Sources/SunbayCheckout/Public/Appearance.swift` (`resolveAddressMode(_:collect:hasUsableEntry:)`), `UI/Content/Components/AddressFormOptions.swift` (add `collectPhone`; `.billing` = (name false, phone false), `.shipping` = (name true, phone true)), `SimpleAddressFormView.swift`, `DynamicAddressFormView.swift` (phone field below the layout rows when `collectPhone`; returned in `addressInput.phone`), `UI/Content/CheckoutContentViewController.swift` (init takes `billingEntryUsable`, `shippingEntryUsable`; passes `*FormShown` flags in `.confirmNewCard`), `UI/PaymentSheet/PaymentSheet.swift` (context gains the two usable flags; calls `controller.evaluateHostEntries`; `UserAction.confirmNewCard(CardInput, save:, billing:, shipping:, billingFormShown:, shippingFormShown:)`), `UI/Wallet/ApplePayButton.swift` (`public var billingAddress: AddressInput? { didSet }`, `shippingAddress` likewise; setters push to `controller.updateHostAddresses`), `Resources/Localizations/{en,zh-Hans}.lproj` (`sunbay.address.phone`), `Core/Localization/SunbayUIStringKeys.swift`
- Test: `Tests/SunbayCheckoutTests/UI/CheckoutContentViewControllerTests.swift`, `PaymentSheetRunCheckoutTests.swift`, `ApplePayButtonTests.swift`, `AppearanceTests.swift` (or the existing appearance test file), localization key coverage test

**Interfaces:**
- Consumes: Task 2 controller API and `AddressRules`.
- Produces: `static func resolveAddressMode(_ mode: AddressCollectionMode, collect: Bool, hasUsableEntry: Bool) -> AddressCollectionMode` (`.automatic` → `collect && !hasUsableEntry ? .full : .off`; others unchanged; the old two-argument overload is removed).

- [ ] **Step 1: Failing tests (simulator).** `resolveAddressMode` table incl. `.automatic` with a usable entry → `.off`, explicit modes ignore the entry; content VC: `.automatic` + `collectBilling:true` + `billingEntryUsable:true` → no billing form; same with `billingEntryUsable:false` → full form; explicit `.simple` with a usable entry → form shown and Pay delivers `billingFormShown == true`; shipping form shows a phone field and the billing form does not (both simple and full); the simple/dynamic shipping `addressInput` carries `phone`; billing `.off` + shipping shown → no same-as-billing checkbox (regression); `ApplePayButton.billingAddress = X` then `= nil` reaches the controller (`usableHostEntry` reflects it); PaymentSheet run: with `.simple` form and a complete host billing entry the diagnostics sink receives one `ADDRESS_ENTRY_IGNORED`; strings `sunbay.address.phone` present in en and zh-Hans.
- [ ] **Step 2:** `xcodebuild test -scheme SunbayCheckout-Package -destination 'id=D8302CDE-6AD6-4593-9A11-6F7BC3C9DB57' -only-testing:SunbayCheckoutTests/CheckoutContentViewControllerTests -only-testing:SunbayCheckoutTests/PaymentSheetRunCheckoutTests -only-testing:SunbayCheckoutTests/ApplePayButtonTests` plus the host filter for the appearance tests → FAIL.
- [ ] **Step 3: Implement.** Update tests that relied on the old resolve overload and on host-over-form behavior.
- [ ] **Step 4:** focused simulator run, full simulator suite once, full `swift test` → 0 failures.
- [ ] **Step 5: Commit**: `feat(address): hide the form when the host supplies a usable address and collect the shipping phone`.

---

### Task 4: Apple Pay request, contacts and `ewalletParam`

**Files:**
- Create: `Sources/SunbayCheckout/Core/ApplePayParams.swift`, `Sources/SunbayCheckout/UI/Wallet/ApplePayAvailability.swift`
- Modify: `Core/Models/CheckoutSession.swift` (internal `var applePayParams: ApplePayParams? = nil`), `Core/ContractDecoding.swift` (decode `ewalletParam` tolerantly and attach `applePayParams` for the `APPLE_PAY` entry), `Core/WalletAuthorizer.swift` (protocol), `UI/Wallet/WalletAuthorizerPassKit.swift`, `UI/Wallet/ApplePayButton.swift`, `UI/Content/CheckoutContentViewController.swift` (tap uses contacts and merchant name; `UserAction.confirmWallet(WalletAuthorization, billingFormShown:, shippingFormShown:)`), `UI/PaymentSheet/PaymentSheet.swift`, test authorizers (`Tests/**/Support`, `Sources/SunbayCheckoutTestSupport` if affected)
- Test: `Tests/SunbayCheckoutTests/Core/ApplePayParamsTests.swift`, `ContractCodableTests.swift`, `WalletAuthorizerTests.swift`, `CheckoutContentViewControllerTests.swift`, `ApplePayButtonTests.swift`

**Interfaces:**
- Produces:
  - `struct ApplePayParams: Equatable, Sendable { var countryCode: String?; var supportedNetworks: [String]; var merchantCapabilities: [String]; static func parse(_ raw: Data?) -> ApplePayParams? }` (`raw` is the JSON of the object; nil/invalid/not an object → nil; non-string elements dropped; only these three keys read)
  - `ContractDecoding.PaymentMethodWire.ewalletParam`: accepts a JSON string containing an object, a JSON object, or null/absent (never throws).
  - `WalletAuthorizing`: `func canMakePayments() -> Bool; func missingParameters(for params: ApplePayParams?) -> [String]; func authorize(amount: Amount, merchantId: String, merchantName: String, params: ApplePayParams?, contacts: WalletContactRequest, confirm: @escaping @Sendable (WalletAuthorization) async -> CheckoutOutcome) async throws -> CheckoutOutcome`
  - `WalletAuthorizer` statics (all pure, host-testable): `networks(from: [String]) -> [PKPaymentNetwork]`, `capabilities(from: [String]) -> PKMerchantCapability`, `makeRequest(amount:merchantId:merchantName:params:contacts:) -> PKPaymentRequest`, `address(from contact: PKContact?) -> AddressInput?` (`isoCountryCode` uppercased to `country`, `state`, `city`, `postalCode`; first street line `line1`, remaining lines joined with ", " as `line2`; given/family name; phone string; nil when the contact has no non-blank field), `email(from contact: PKContact?) -> String?`. The delegate builds a `WalletAuthorization` from `payment.token.paymentData`, `billingContact`, `shippingContact` (email = shipping email else billing email).
  - `enum ApplePayAvailability { static func evaluate(session: CheckoutSession, hiddenByFilter: Bool, authorizer: any WalletAuthorizing, merchantId: String?) -> Result }` with `struct Result: Equatable { let available: Bool; let missing: [String] }`: available iff the session has an `APPLE_PAY` entry, not hidden, device can pay, merchant id non-nil and `missing` empty.

- [ ] **Step 1: Failing tests.** Parse: JSON object string with all three keys; object with extras ignored; invalid JSON → nil; `supportedNetworks` containing a number → number dropped; empty arrays kept as empty. Session decode: dev-shaped payload (`ewalletParam` as a JSON string with the six networks and three capabilities seen on dev) → `applePayParams` equals them; payload with `ewalletParam` as an object → same; malformed/absent → nil and the session still decodes. PassKit statics (host): networks `["chinaUnionPay","amex","discover","masterCard","jcb","visa","bogus","visa"]` → `[.chinaUnionPay,.amex,.discover,.masterCard,.JCB,.visa]`; capabilities `["supports3DS","supportsCredit","supportsDebit","x"]` → 3DS|Credit|Debit; `missingParameters(nil)` = `["supportedNetworks","merchantCapabilities"]`, all-unknown networks → `["supportedNetworks"]`, empty capabilities → `["merchantCapabilities"]`, full params → `[]`; `makeRequest`: country default `US`, `" gb "` → `GB`, label merchant name / "Total" fallback, summary amount from minor units, contact field sets exactly as the Global Constraints, none requested → empty sets; `address(from:)`: street `"1 Main St\nApt 2"` → line1/line2, `us` → `US`, names, phone, empty contact → nil, nil → nil. Content VC / button with a fake authorizer: tap calls `authorize` with `contacts` equal to `controller.walletContactRequest(...)`; the fake's `confirm` call with a `WalletAuthorization` carrying billing/shipping reaches `confirmWallet` and the submitted request has those addresses and `customerEmail`; availability: missing parameters → Apple Pay row absent (sheet) / button unavailable, and exactly one `WALLET_PARAMS_INVALID` with `ignored` = the missing names (never values).
- [ ] **Step 2:** `swift test --filter 'ApplePayParamsTests|ContractCodableTests|WalletAuthorizerTests'` (host) and the simulator filter for content/button tests → FAIL.
- [ ] **Step 3: Implement.** Existing fake/mock authorizers gain `missingParameters` returning `[]` and the new `authorize` signature; existing fixtures that expect Apple Pay to show now include valid `applePayParams` (or use the fake authorizer's empty `missing`).
- [ ] **Step 4:** focused runs, full simulator suite once, full `swift test`.
- [ ] **Step 5: Commit**: `feat(applepay): request contacts, read ewalletParam and submit wallet addresses`.

---

### Task 5: Provider registry, payment-method filter, empty result

**Files:**
- Create: `Sources/SunbayCheckout/Public/PaymentMethodFilter.swift`, `Sources/SunbayCheckout/Core/PaymentMethodModel.swift`, `Sources/SunbayCheckout/Core/PaymentProviderRegistry.swift`
- Modify: `Public/CheckoutConfiguration.swift` (`paymentMethodFilter`, both init variants, defaulted last parameter), `Core/Models/CheckoutSession.swift` (internal `var methodEntries: [MethodEntry] = []`), `Core/ContractDecoding.swift` (fill `methodEntries` in backend order), `UI/PaymentSheet/PaymentSheet.swift` (filter + availability before UI; `NO_PAYMENT_METHOD_AVAILABLE`; filter warnings; skip saved-card listing when `CARD` unavailable), `UI/Content/CheckoutContentViewController.swift` (render groups from the providers: express group above/below per `expressPosition`, normal group; new-card row and saved cards only when `CARD` is available), `UI/Wallet/ApplePayButton.swift` (hidden by filter → unavailable)
- Test: `Tests/SunbayCheckoutTests/Core/PaymentMethodModelTests.swift`, `PaymentProviderRegistryTests.swift`, `ContractCodableTests.swift`, `UI/PaymentSheetRunCheckoutTests.swift`, `UI/CheckoutContentViewControllerTests.swift`, `UI/ApplePayButtonTests.swift`

**Interfaces:**
- Produces:
  - `public struct PaymentMethodID: RawRepresentable, Hashable, Sendable, ExpressibleByStringLiteral { public let rawValue: String; public init(rawValue: String); public init(stringLiteral:); public static let card, applePay }` (`"CARD"`, `"APPLE_PAY"`); `public struct PaymentMethodFilter: Sendable, Equatable { public var hide: [PaymentMethodID]; public var order: [PaymentMethodID]; public init(hide: [PaymentMethodID] = [], order: [PaymentMethodID] = []) }`; `CheckoutConfiguration.paymentMethodFilter: PaymentMethodFilter` (default empty).
  - `struct MethodEntry: Equatable, Sendable { let method: String; let type: String; let name: String; let logoURL: String? }`
  - `enum PaymentMethodModel { static func logicalKey(_ e: MethodEntry) -> String; struct FilterIgnored: Equatable { let identifier: String; let reason: String }; static func apply(_ filter: PaymentMethodFilter, to entries: [MethodEntry]) -> (entries: [MethodEntry], ignored: [FilterIgnored]) }` (reason text lists the available logical keys and raw methods, comma separated, never fails)
  - `struct PaymentProvider: Equatable { enum Kind { case express, normal }; let key: String; let kind: Kind }`; `enum PaymentProviderRegistry { static let all: [PaymentProvider]` (`APPLE_PAY` express, `CARD` normal)`; static func available(entries: [MethodEntry], isStaticallyAvailable: (PaymentProvider) -> Bool) -> [PaymentProvider] }` (entry-order per group; provider listed iff some entry's logical key equals its key and the static check passes)
  - `PaymentSheet`: after `controller.start`, compute `filtered = PaymentMethodModel.apply(config.paymentMethodFilter, to: session.methodEntries)`, report each ignored identifier as `PAYMENT_METHOD_FILTER_IGNORED` (`ignored: [identifier]`), compute `available` with the Apple Pay static check from `ApplePayAvailability` (Task 4) and `CARD` always statically available; none available → return `.failed(txnId: nil, error: CheckoutError(code: "NO_PAYMENT_METHOD_AVAILABLE", message: "No payment method is available for this checkout.", category: .configuration, traceId: nil))`.

- [ ] **Step 1: Failing tests.** Model (host): table from the Global Constraints: `hide ["CARD"]` removes all card entries; `hide ["AMEX"]` removes one brand and is not ignored; `hide ["applePay"]`, `[""]`, a duplicate and a never-present id → entries unchanged / appropriately removed and the unknown ones in `ignored` once each with a reason listing the available identifiers; `hide` + `order` same id → hidden, no ignored; `order ["GOOGLE_PAY","CARD"]` with no Google entry → one ignored, cards first in original relative order; empty filter returns entries equal to input; everything hidden → empty; input not mutated; a property test (random id arrays) asserts the result is a subsequence-permutation of the input and `ignored` has no duplicates. Registry: card + Apple Pay available, grouped; `APPLE_PAY` static false → card only; `CARD` hidden → Apple Pay only; no entries → empty. Session decode keeps backend order and every entry. Sheet (simulator): `hide ["APPLE_PAY"]` → no express row; `hide ["CARD"]` → no new-card row and no saved-card list request (cof service call count 0) but Apple Pay row present; hide both → `present` returns `.failed` `NO_PAYMENT_METHOD_AVAILABLE` and no sheet is presented; session without a card entry → no new-card row (HPP parity); `expressPosition: .bottom` still places the express group below; one `PAYMENT_METHOD_FILTER_IGNORED` per unknown id delivered through `onDiagnostic`. Button: `hide ["APPLE_PAY"]` → `isAvailable == false`.
- [ ] **Step 2:** host filter `PaymentMethodModelTests|PaymentProviderRegistryTests|ContractCodableTests`, then the simulator filters → FAIL.
- [ ] **Step 3: Implement.** Update existing UI tests whose fixtures lack `methodEntries` (add entries in the fixtures rather than defaulting to "card always").
- [ ] **Step 4:** focused runs, full simulator suite once, full `swift test`.
- [ ] **Step 5: Commit**: `feat(methods): add the provider registry, payment-method filter and empty-result failure`.

---

### Task 6: Example, real-API checks, docs

**Files:**
- Modify: `Example/SunbayCheckoutDemo/Sources/DemoSettings.swift`, `DemoRootView.swift` (toggles: hide Apple Pay, hide Card, pass a complete host shipping address as well as the existing host billing toggle; a "Diagnostics" section listing events received through `checkout.onDiagnostic` (code, ignored, reason only); show them in the outcome area), `Tests/SunbayCheckoutRealAPITests/` (new `RealAPIWalletTests.swift`), `docs/product-spec.md` (§2.1 `paymentMethodFilter`, `onDiagnostic`, address rules replacing the phase-3 sentences in §7.3, Apple Pay request rules), `docs/real-api-integration-checklist.md`, `Example/README.md`
- Not changed: `docs/backend-native-wallet-params.md` (already final for this scope).

- [ ] **Step 1: Real-API tests** (skip rules as in earlier real-API tests): (a) live session decode: `applePayParams` non-nil, `supportedNetworks`/`merchantCapabilities` non-empty, `WalletAuthorizer.networks(from:)` yields at least one network and `capabilities(from:)` contains 3DS, `WalletAuthorizer.makeRequest(...).countryCode == "US"`; (b) live `methodEntries` include `CARD`-typed entries and `APPLE_PAY`; `PaymentMethodModel.apply(hide ["CARD"])` removes every card entry and keeps Apple Pay; (c) with the sandbox card (skip without env) a new-card submit that supplies a complete host billing address and `collectBillingAddress: true` is submitted with `payerBillingInfo` (outcome recorded as a diagnostic string, assert only that the code is not `C01`). Run `scripts/run-dev-e2e.sh` without card env; the controller reruns it with the card.
- [ ] **Step 2: Example** changes; `tuist generate --no-open` in `Example/SunbayCheckoutDemo`; simulator build `xcodebuild -workspace Example/SunbayCheckoutDemo/SunbayCheckoutDemo.xcworkspace -scheme SunbayCheckoutDemo -destination 'generic/platform=iOS Simulator' build` → BUILD SUCCEEDED.
- [ ] **Step 3: Docs (English).** product-spec: replace the phase-3 "host wins / hide the billing form" sentences with the JS-aligned rules (Global Constraints), document `.automatic` hiding the form for a usable host entry, `PaymentMethodFilter` (identifiers, case sensitivity, `order` within group, `hide: ["CARD"]` also hides saved cards, empty-result failure), `onDiagnostic` (main thread, buffering, codes), Apple Pay request rules (country default `US`, case-insensitive network lookup, hidden when parameters are missing). Checklist: behavior corrections to unreleased phase 3 for the first release notes (host address gating, form-over-host precedence); `WALLET_PARAMS_INVALID` must be registered in the shared `WARNING_CODES` and the JS `api.md` code table (JS owns it); open verification items on a real device: Apple Pay sheet requesting and returning contacts, the token format accepted by the backend, `customerName`/`customerEmail` acceptance; Apple Pay merchant id and certificate onboarding (backend). 
- [ ] **Step 4:** full `swift test` → 0 failures.
- [ ] **Step 5: Commit**: `test(wallet): real-API wallet and filter checks, Example options and docs`.

---

## Self-review notes

- Spec coverage: 5.1 (Tasks 2, 3), 5.2 (Task 4), 5.3 (Task 5), 5.4 (Task 1, plus warnings emitted in Tasks 2, 4, 5), 5.5 public API (Tasks 1, 3, 5), 5.6 verification (each task, Task 6). Backend/Android items stay open as in spec section 6.
- Names used across tasks: `DiagnosticsReporter` (`warning`, `error`, `resetWarnings`), `AddressKind`, `AddressRules`, `WalletContactRequest`, `WalletAuthorization`, `CheckoutController.usableHostEntry/evaluateHostEntries/walletContactRequest/updateHostAddresses`, `resolveAddressMode(_:collect:hasUsableEntry:)`, `ApplePayParams`, `ApplePayAvailability`, `MethodEntry`, `PaymentMethodModel.apply`, `PaymentProviderRegistry.available`.
- Ordering: Task 2 needs Task 1's reporter; Task 3 needs Task 2; Task 4 needs Tasks 1-3; Task 5 needs Tasks 1 and 4 (`ApplePayAvailability`); Task 6 last.
- Known risk: PassKit `PKContact` mapping and the real sheet need a real device; host tests cover the pure conversions only.
