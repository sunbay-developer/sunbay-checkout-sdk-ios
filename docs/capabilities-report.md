# SunbayCheckout iOS SDK — Capabilities & Functional Status Report

> Version: `0.0.1` (first-release implementation, mock-backed / pre-backend-integration)
> Date: 2026-10-27
> Source of truth: the merged `main` branch (16 feature commits + translation). Every capability
> below is backed by shipped, reviewed code and 43 passing tests — this is a status report of
> what exists, not a roadmap.
> Legend: ✅ implemented · ⚠️ placeholder / partial · ⛔ not implemented (reserved/tracked)

---

## 1. Executive summary

The SDK is a **pure-native** iOS payment SDK (no embedded WebView for card collection). Its first
release delivers two integration surfaces — a black-box **PaymentSheet (L1)** and embeddable
**Elements (`CheckoutElements` / `ExpressCheckoutElement` / `CardElement`)** (L2) — over a UI-agnostic core, with **Card-on-File (COF)** saved-card one-tap
pay as a first-release feature. It runs end-to-end today against an **injected mock backend**; a
real backend adapter is intentionally not built yet (the backend contract is undefined) and plugs
into a ready public injection seam.

**Production-ready now:** architecture, public API shape, security boundaries, payment state
machine, and the mock-driven flows. **Gated before a real integration:** four backend-alignment
items in §7.

---

## 2. Supported payment methods

| Method | Status | Notes |
|---|---|---|
| New card (manual entry) | ✅ | Native `CardField`; data RSA-encrypted on-device, submitted as `cardEncryptedData`. |
| Save card at payment (COF enrol) | ✅ | "Save this card" toggle → `savePaymentMethod` + `consent`. No standalone "add card" flow (by design). |
| Saved card one-tap (COF) | ✅ | Lists masked saved cards, select-and-pay with **zero extra verification** (per product decision; backed by short-TTL + transaction-scoped tokens + backend risk control). |
| Apple Pay — standalone button | ✅ | PassKit; real token flow pending real-device verification (§7). |
| Apple Pay — inside PaymentSheet | ⚠️ | Entry row is a **cancel-only placeholder**; the standalone button is the working wallet path this release. |
| Google Pay | ⛔ | Android concern; not part of the iOS SDK. |
| 3DS / CVC step-up | ⛔ | Not implemented; the `requiresAction` path is reserved so the backend can trigger step-up later without a client change. |

## 3. Integration surfaces (UI shells)

| Surface | Status | What it is |
|---|---|---|
| **L1 `PaymentSheet`** | ✅ | Black-box modal page. `present(from:) async -> CheckoutOutcome`. Auto-renders new-card + COF saved cards (when enabled) + Apple Pay entry. Host writes almost no UI code. |
| **L2 Elements: `CheckoutElements` + `ExpressCheckoutElement` + `CardElement`** | ✅ | L2 is now Elements. One group per session shares one payment lock, expiry timer and outcome history. `CardElement` embeds saved cards (COF) and the inline new-card form (optional billing / shipping address forms); the merchant owns the Pay button and calls `CheckoutElements.confirm()`. See the Elements chapter below. |

### 3.1 Elements chapter

```swift
let elements = try await CheckoutElements.create(checkout: checkout, sessionId: sessionId)
let express = elements.makeExpressCheckoutElement()   // Apple Pay, tap pays immediately -> onResult
let card = elements.makeCardElement()                 // saved cards + inline new-card form
// Merchant's own Pay button:
let outcome = await elements.confirm()                // pays the CardElement selection
```

- **Config precedence:** the backend decides whether an address is collected; global `Appearance` switches and the
  component settings can only turn a form off, never on. `PaymentMethodFilter` and provider availability always win
  over per-component settings.
- **`confirm()`:** amount always from the server session; `CARD_INPUT_INVALID` (nothing submitted, inline errors, no
  lock) and `NO_PAYMENT_OPTION_SELECTED` are returned as `.failed`; after a settled payment or ended session the stored
  outcome is returned again.
- **No notices rendered:** the components show only inline field errors; the host shows outcomes.
- **Pending / unknown:** components stay disabled, `confirm()` returns the stored outcome, and the host reconciles via
  `retrievePayment()` / webhook. The SDK does not poll.
- **One `CardElement` per group** (a second `makeCardElement` returns the same instance).
- **Keyboard insets are the host's job.**
- `ExpressCheckoutElement` replaces the removed `ApplePayButton`.
- **Security:** inline card fields are real views in the merchant's view hierarchy; see `docs/security-and-pci.md` §9
  (host PCI scope and the QSA / acquirer release gate; fallback for strict merchants: `PaymentSheet`).

## 4. Core capabilities

| Capability | Status | Notes |
|---|---|---|
| Single orchestrator (`CheckoutController`, actor) | ✅ | All three paths share one state machine. |
| Payment state machine (idle→load→ready→authorize→submit→terminal) | ✅ | Four outcomes: succeeded / failed / pending / plus canceled & unknown. |
| Single-active-session guard | ✅ | A second concurrent confirm returns `alreadyPresenting`; one attemptId per click. |
| Idempotency (attemptId per attempt) | ✅ | Carried on every submit. |
| "Submit failed → query, never blind-retry" | ✅ | On submit error: one `getResult`; still failing → `unknown`. |
| Result dedup (terminal delivered once) | ✅ | Proven with a real two-source (submit→pending, poll→terminal) test. |
| Result polling with backoff | ✅ | 1s→5s backoff, ~90s overall cap; on-limit non-terminal → `unknown`. |
| App-lifecycle recovery | ✅ | `retrievePayment(sessionId:)` is a UI-independent query for crash/kill recovery. |
| RSA card encryption (chunked, matches web `encryptLong`) | ✅ | Chunk > 1 block proven round-trip. PKCS#1 v1.5; key-format pending backend (§7). |
| `requiresAction` dispatch | ✅ | `redirect` → `ASWebAuthenticationSession` → pending; `qrCode`/`showContent`/unknown → `UNSUPPORTED_CAPABILITY`. |
| COF saved-card listing (direct-to-PSP) | ✅ | `CofService.listPaymentMethods`; fail-soft (degrades to new-card only). |
| Credential discipline | ✅ | `customerAccessSecret` memory-only (`CredentialStore`), cleared on terminal/dismiss; never logged/persisted/returned. |
| Public service injection seam | ✅ | `SunbayCheckout(configuration:paymentService:cofService:)` lets a host inject mock or real adapters. |
| Fail-closed default services | ✅ | Plain `init(configuration:)` → `NETWORK_UNAVAILABLE` (never fakes success). |

## 5. Public API surface (semver-stable candidate)

Entry & config: `SunbayCheckout`, `CheckoutConfiguration` (+ `Environment`), `sunbayCheckoutVersion`.
UI: `PaymentSheet`, `CheckoutElements`, `ExpressCheckoutElement`, `CardElement` (skeleton) (+ `Appearance.ApplePayButtonStyle`, `ApplePayButtonType`).
Results/errors: `CheckoutOutcome`, `CheckoutError` (+ `Category`), `PaymentSnapshot`, `TxnStatus`.
Models: `Amount`, `SavedCard`, `CheckoutSession`, `PaymentMethodKind`, `PaymentAction`, `Appearance` (+ `ColorScheme`).
Host-implemented contracts: `PaymentService`, `CofService`, `SubmitRequest`, `Consent`.

Internal (not exposed): `CheckoutController`, `CardEncryptor`, `CardInput`, `CredentialStore`,
`ResultPoller`, `ActionHandler`/`ActionHandling`, `WalletAuthorizer`, `PaymentSheetViewController`,
the Unconfigured* defaults.

## 6. Internationalization (i18n)

⛔ **Not implemented.** `CheckoutConfiguration.locale` exists but is **stored, not consumed** —
nothing switches copy by locale. All PaymentSheet UI strings are **hardcoded English**
("Cancel", "Pay", "Save this card", "New card", "Saved cards", "Apple Pay"). There is no string
catalog / localization pipeline. Shipping non-English UI is a tracked gap (not in first-release
scope).

## 7. Backend-alignment items (gate a real integration — all tracked, none hidden)

| # | Item | Why it matters | Behavior today |
|---|---|---|---|
| P0-1 | RSA public-key format | Encryptor imports PKCS#1 DER; web/JSEncrypt likely emits X.509 SPKI | Mismatch throws `invalidPublicKey` — **fails loud**, isolated to one function |
| P0-2 | Currency minor-unit decimals | `WalletAuthorizer.makeRequest` hardcodes `/100` | Wrong Apple Pay amount for JPY / zero-decimal / 3-decimal currencies — fix before sandbox |
| P0-3 | Real-device Apple Pay token | Full capability→sheet→token needs device + entitlement + sandbox card | Probe builds for sim (no-card branch expected); **real-device run is an outstanding manual step** |
| P0-4 | Real HTTP `PaymentService`/`CofService` adapter | Not built — backend contract undefined (§7/§8 of product-spec) | Public injection seam is the designed, non-breaking insertion point |

Minor tracked items: in-sheet Apple Pay wiring (v-next), `Consent` version hardcoded,
`PaymentActionProviding` keyed by "latest" not txnId, malformed-redirect → `.unknown`.

## 8. Example coverage & verification

- **Example app (`SunbayCheckoutDemo`)** — public-API-only; injects the mock backend via the
  public seam; demonstrates: PaymentSheet (new-card, COF saved-card one-tap, Apple Pay entry row),
  the Elements section (Express element), a scenario picker driving all five outcomes
  (succeeded / failed / pending / requiresAction / networkTimeout→unknown). Builds and launches on
  the iOS Simulator.
- **Apple Pay probe (`ApplePayProbe`)** — standalone, PassKit-direct; validates the client wallet
  call chain with redacted token diagnostics; real-device run is the manual step (P0-3).
- **Tests** — 43 XCTest on the macOS host (Core logic), plus UIKit-gated tests that run on the iOS
  simulator. All green.
- **Distribution** — Swift Package Manager (library `SunbayCheckout` + two example executables).
  XCFramework reserved/on-demand; CocoaPods not planned.

## 9. One-line verdict

A coherent, security-disciplined, well-tested **first-release implementation** that runs end-to-end
against mocks and is ready as an architecture + public-API freeze; **four backend-alignment items
(§7) must close before a real payment integration**, and i18n is a known future gap.
