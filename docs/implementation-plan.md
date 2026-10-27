# Sunbay Checkout iOS SDK — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build the first release of the Sunbay Checkout iOS SDK — a pure-native payment SDK with a black-box PaymentSheet (L1), a standalone ApplePayButton (L3), and one-tap COF (saved card) payment, all driven by a UI-agnostic Core.

**Architecture:** A single UI-agnostic `CheckoutController` (Swift `actor`) orchestrates three payment paths (new card / Apple Pay / COF saved card) over injected protocols (`PaymentService`, `CofService`). Plaintext card data touches only `CardEncryptor`; secrets touch only `CredentialStore`. UI shells (PaymentSheet, ApplePayButton) render and forward user actions; they hold no business logic. L2 (EmbeddedPaymentElement) is a reserved directory, not implemented.

**Tech Stack:** Swift 5.9+, Swift Concurrency (actor/async), PassKit, Security framework (RSA), URLSession, AuthenticationServices (ASWebAuthenticationSession), Swift Package Manager, XCTest.

**Spec:** `docs/product-spec.md` (self-contained; inlines backend contract, COF model, RSA details). Security: `docs/security-and-pci.md`.

## Global Constraints

- **Swift only.** Minimum iOS target: iOS 15 (prototype floor; locked after real-device verification). Package name / products: library `SunbayCheckout`.
- **Distribution:** Swift Package Manager primary. No CocoaPods. XCFramework not built in first release.
- **Small stable public API.** Internal types must not be `public`. Semantic versioning.
- **Card values, wallet tokens, COF secrets, and the RSA-encrypted payload must never** appear in logs, analytics, crash reports, or any public callback/return value.
- **Sensitive data boundary:** only `CardEncryptor` touches plaintext card data (zeroed immediately after encryption); only `CredentialStore` holds secrets (memory-only, cleared on terminal state). Nothing sensitive is persisted (no UserDefaults / file / Keychain / UIPasteboard).
- **Core is UI-agnostic:** `Core/` imports no UIKit/PassKit UI types; depends on protocols only.
- **Payment truth = server-confirmed terminal state** (`S`/`F`). Wallet/COF authorization success is not a transaction result. On submit failure/timeout, query (`getResult`) before any resubmit; never blind-retry.
- **Backend contract is a mock baseline** (product-spec §7). `PaymentService`/`CofService` are protocols; the mock is swapped for the real adapter later without touching Core/UI.
- **Amounts** use integer minor currency units.
- **RSA algorithm/padding must match the backend** before `CardEncryptor` ships (product-spec §8 D6 / §7.2). Until confirmed, implement against PKCS#1 v1.5 (`.rsaEncryptionPKCS1`) and isolate the choice behind one constant.

## Review Focus

- **Submit network timeout** → Core must enter `unknown` / query via `getResult`, never resubmit with a new attemptId (Task 6, Task 7 tests).
- **Double-tap / concurrent confirm** → second confirm while one is active returns `alreadyPresenting`; only one attemptId per click (Task 6 tests).
- **Late/duplicate terminal result** → a terminal outcome is delivered to the UI exactly once; a second result for the same attempt is dropped (Task 6 tests).
- **RSA plaintext larger than one block** → `CardEncryptor` must chunk and concatenate into one valid base64 (matches web `encryptLong`); a long PAN+payload must not silently truncate (Task 4 tests).
- **`requiresAction` with an unsupported action type** (`qrCode`/`showContent`) → maps to `failed(UNSUPPORTED_CAPABILITY)`, not a silent hang; `redirect` → `pending` after opening the auth session (Task 8 tests).

---

## Task 1: Swift package skeleton

**Files:**
- Create: `Package.swift`
- Create: `Sources/SunbayCheckout/SunbayCheckout.swift` (umbrella / version constant)
- Create: `Tests/SunbayCheckoutTests/PackageSmokeTests.swift`
- Create: `.gitignore`

**Interfaces:**
- Produces: library product `SunbayCheckout`; `public let sunbayCheckoutVersion: String`.

- [ ] **Step 1: Write the failing test**

```swift
import XCTest
@testable import SunbayCheckout

final class PackageSmokeTests: XCTestCase {
    func test_version_isNonEmptySemver() {
        XCTAssertFalse(sunbayCheckoutVersion.isEmpty)
        XCTAssertEqual(sunbayCheckoutVersion.split(separator: ".").count, 3)
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test` — Expected: build failure (no `SunbayCheckout` target / symbol).

- [ ] **Step 3: Create `Package.swift`** declaring one library product `SunbayCheckout`, platform `.iOS(.v15)`, swift-tools 5.9, one test target. Create `SunbayCheckout.swift` with `public let sunbayCheckoutVersion = "0.0.1"`. Create a Swift/Xcode `.gitignore` (`.build/`, `*.xcodeproj` user data, `.DS_Store`).

- [ ] **Step 4: Run test to verify it passes**

Run: `swift test` — Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add Package.swift Sources/SunbayCheckout/SunbayCheckout.swift Tests/SunbayCheckoutTests/PackageSmokeTests.swift .gitignore
git commit -m "chore: scaffold SunbayCheckout Swift package"
```

---

## Task 2: Core models

**Files:**
- Create: `Sources/SunbayCheckout/Core/Models/Amount.swift`
- Create: `Sources/SunbayCheckout/Core/Models/CheckoutSession.swift`
- Create: `Sources/SunbayCheckout/Core/Models/SavedCard.swift`
- Create: `Sources/SunbayCheckout/Core/Models/PaymentSnapshot.swift`
- Create: `Sources/SunbayCheckout/Public/CheckoutOutcome.swift`
- Create: `Sources/SunbayCheckout/Public/CheckoutError.swift`
- Test: `Tests/SunbayCheckoutTests/Core/ModelsTests.swift`

**Interfaces:**
- Produces:
  - `public struct Amount: Sendable, Equatable { public let minorUnits: Int64; public let currencyCode: String }`
  - `struct CheckoutSession: Sendable, Equatable` with `id, amount, merchantName, methods: Set<PaymentMethodKind>, expiresAt: Date, rsaPublicKey: String?, cofEnabled: Bool`
  - `enum PaymentMethodKind: String, Sendable { case card, applePay, savedCard }`
  - `public struct SavedCard: Sendable, Equatable { id, brand, last4, expMonth, expYear }`
  - `public enum TxnStatus: String { case initial = "I", succeeded = "S", failed = "F", requiresAction = "R" }`
  - `public struct PaymentSnapshot: Sendable, Equatable { sessionId, status: TxnStatus, txnId: String? }`
  - `public enum CheckoutOutcome: Sendable` — cases `succeeded(txnId:)`, `failed(txnId:error:)`, `canceled`, `pending(txnId:)`, `unknown(sessionId:)`
  - `public struct CheckoutError: Error, Sendable` — `code, message, category, traceId?`; `public enum Category { case configuration, validation, network, runtime, payment }`

- [ ] **Step 1: Write the failing test** — assert `TxnStatus(rawValue:)` maps `"I"/"S"/"F"/"R"`; `Amount` equality; `CheckoutOutcome`/`CheckoutError` construct and are `Equatable` where declared.

```swift
func test_txnStatus_rawValues() {
    XCTAssertEqual(TxnStatus(rawValue: "S"), .succeeded)
    XCTAssertEqual(TxnStatus(rawValue: "R"), .requiresAction)
}
func test_amount_equatable() {
    XCTAssertEqual(Amount(minorUnits: 999, currencyCode: "USD"),
                   Amount(minorUnits: 999, currencyCode: "USD"))
}
```

- [ ] **Step 2: Run** `swift test` — Expected: FAIL (types undefined).
- [ ] **Step 3: Implement the types** exactly as in Interfaces. No logic beyond stored properties and the enum raw values.
- [ ] **Step 4: Run** `swift test` — Expected: PASS.
- [ ] **Step 5: Commit** `git commit -m "feat: core payment models and public result/error types"`

---

## Task 3: Backend contract types + PaymentService / CofService protocols

**Files:**
- Create: `Sources/SunbayCheckout/Core/PaymentService.swift` (protocol + request/response DTOs)
- Create: `Sources/SunbayCheckout/Core/CofService.swift` (protocol)
- Create: `Sources/SunbayCheckout/Core/PaymentAction.swift`
- Test: `Tests/SunbayCheckoutTests/Core/ContractCodableTests.swift`

**Interfaces:**
- Produces:
  - `struct SubmitRequest: Sendable { sessionId, paymentMethod, attemptId: UUID, cardEncryptedData: String?, walletToken: Data?, paymentMethodId: String?, savePaymentMethod: Bool?, consent: Consent? }`
  - `struct Consent: Codable, Sendable { let version: String; let futureUsage: String }` (value `"ON_SESSION"`)
  - `enum PaymentAction: Sendable, Equatable { case redirect(url: URL), qrCode, showContent, unknown }`
  - `protocol PaymentService: Sendable { func loadSession(_ id: String) async throws -> CheckoutSession; func submit(_ req: SubmitRequest) async throws -> PaymentSnapshot; func getResult(sessionId: String) async throws -> PaymentSnapshot }`
  - `protocol CofService: Sendable { func listPaymentMethods(customerAccessSecret: String, sessionId: String) async throws -> [SavedCard] }`
  - Decoding helper that maps the backend JSON of product-spec §7.1/§7.4 into `CheckoutSession`/`PaymentSnapshot`/`PaymentAction`.

- [ ] **Step 1: Write the failing test** — decode a sample session JSON (product-spec §7.1 fields incl. `rsaPublicKey`, `cofEnabled`) into `CheckoutSession`; decode a `txnStatus="R"` result with `action.type="redirect"` into `PaymentSnapshot` + `PaymentAction.redirect`; decode `action.type="qrCode"` into `.qrCode`.
- [ ] **Step 2: Run** `swift test` — Expected: FAIL.
- [ ] **Step 3: Implement** the DTOs, protocols, and the JSON→model decoding. Keep protocols UI-free and `Sendable`.
- [ ] **Step 4: Run** `swift test` — Expected: PASS.
- [ ] **Step 5: Commit** `git commit -m "feat: backend contract DTOs and service protocols"`

---

## Task 4: CardEncryptor (RSA local encryption)

**Files:**
- Create: `Sources/SunbayCheckout/Core/CardEncryptor.swift`
- Test: `Tests/SunbayCheckoutTests/Core/CardEncryptorTests.swift`
- Test fixture: generate an RSA key pair in-test (Security framework) to encrypt then decrypt.

**Interfaces:**
- Consumes: nothing from other tasks.
- Produces:
  - `struct CardInput: Sendable { cardNumber, expiryMonth, expiryYear, cvv: String }`
  - `enum CardEncryptor { static func encrypt(_ card: CardInput, rsaPublicKeyBase64: String, now: () -> Date = Date.init) throws -> String }`
  - Builds JSON `{cardNumber, expiryMonth, expiryYear, cvv, timeStamp}` (timeStamp = ms string), RSA-encrypts with **chunking** (block size derived from key modulus; PKCS#1 v1.5), concatenates ciphertext blocks, returns one base64 string. One internal constant `rsaAlgorithm = .rsaEncryptionPKCS1` isolates the padding choice (product-spec §8 D6).

- [ ] **Step 1: Write the failing test**

```swift
func test_encrypt_thenDecrypt_roundTrips_longPayload() throws {
    let (pub, priv) = try Self.makeRSAKeyPair(bits: 2048)
    let input = CardInput(cardNumber: "4242424242424242",
                          expiryMonth: "12", expiryYear: "2029", cvv: "123")
    let b64 = try CardEncryptor.encrypt(input, rsaPublicKeyBase64: pub,
                                        now: { Date(timeIntervalSince1970: 1_700_000_000) })
    let json = try Self.rsaDecryptChunked(base64: b64, privateKey: priv)
    let obj = try JSONSerialization.jsonObject(with: json) as! [String: String]
    XCTAssertEqual(obj["cardNumber"], "4242424242424242")
    XCTAssertEqual(obj["cvv"], "123")
    XCTAssertEqual(obj["timeStamp"], "1700000000000")
}
```

- [ ] **Step 2: Run** `swift test` — Expected: FAIL.
- [ ] **Step 3: Implement** `CardEncryptor.encrypt` using `SecKeyCreateEncryptedData` per chunk. Chunk the plaintext to the max input size for the key+padding; concatenate encrypted blocks; base64-encode the concatenation. (Test provides the matching chunked-decrypt helper, mirroring the backend.)
- [ ] **Step 4: Run** `swift test` — Expected: PASS (incl. the long-payload case that forces >1 block).
- [ ] **Step 5: Commit** `git commit -m "feat: RSA card encryptor with chunking (matches web encryptLong)"`

---

## Task 5: CredentialStore (memory-only secrets)

**Files:**
- Create: `Sources/SunbayCheckout/Core/CredentialStore.swift`
- Test: `Tests/SunbayCheckoutTests/Core/CredentialStoreTests.swift`

**Interfaces:**
- Produces: `actor CredentialStore { func hold(customerAccessSecret: String); func current() -> String?; func clear() }` — memory only; `clear()` is idempotent.

- [ ] **Step 1: Write the failing test** — `hold` then `current` returns it; `clear` then `current` returns nil; `clear` twice is safe.
- [ ] **Step 2: Run** `swift test` — Expected: FAIL.
- [ ] **Step 3: Implement** the actor. No persistence, no logging.
- [ ] **Step 4: Run** `swift test` — Expected: PASS.
- [ ] **Step 5: Commit** `git commit -m "feat: memory-only credential store"`

---

## Task 6: CheckoutController — orchestration, state machine, invariants

**Files:**
- Create: `Sources/SunbayCheckout/Core/CheckoutController.swift`
- Test: `Tests/SunbayCheckoutTests/Core/CheckoutControllerTests.swift`
- Test helper: `Tests/SunbayCheckoutTests/Support/MockPaymentService.swift`, `MockCofService.swift` (scriptable results/errors/delays)

**Interfaces:**
- Consumes: `PaymentService`, `CofService`, `CardEncryptor`, `CredentialStore`, `ActionHandling` (Task 8, injected as a protocol so this task can land before the UI-bound implementation — provide a no-op test double here).
- Produces: `actor CheckoutController` with:
  - `init(paymentService:cofService:credentials:actionHandler:)`
  - `func start(sessionId: String, customerAccessSecret: String?) async throws -> CheckoutSession`
  - `func listSavedCards() async -> [SavedCard]` (empty on COF-disabled or list failure — degrade to new-card only)
  - `func confirmNewCard(_ input: CardInput, save: Bool, consent: Consent?) async -> CheckoutOutcome`
  - `func confirmSavedCard(paymentMethodId: String) async -> CheckoutOutcome`
  - `func confirmWallet(token: Data) async -> CheckoutOutcome`
  - `func retrievePayment(sessionId: String) async throws -> PaymentSnapshot`
  - `func dismiss()`
  - Internal mapping `PaymentSnapshot → CheckoutOutcome`: `S→succeeded`, `F→failed`, `I→pending`, `R→` delegate to `actionHandler`.

- [ ] **Step 1: Write the failing tests** (one XCTest each):
  - `test_singleActiveSession_secondConfirmReturnsAlreadyPresenting` — while a slow confirm is in flight, a second confirm returns `failed(... .alreadyPresenting)` and does not create a second attemptId (assert mock saw exactly one submit).
  - `test_submitTimeout_queriesResult_neverResubmits` — `submit` throws a network error; controller calls `getResult` once and maps its snapshot; mock `submit` call count stays 1.
  - `test_duplicateTerminalResult_deliveredOnce` — feed two identical terminal snapshots for one attempt; outcome resolves once (second is dropped).
  - `test_newCard_encryptsAndSubmits` — asserts the submitted `cardEncryptedData` is non-empty and `paymentMethodId` is nil.
  - `test_savedCard_submitsPaymentMethodId_noCardData` — asserts submit carries `paymentMethodId` and nil `cardEncryptedData`.
  - `test_cofDisabled_listSavedCardsEmpty` — session `cofEnabled=false` → `listSavedCards` returns `[]` without calling `CofService`.
  - `test_terminalState_clearsCredentials` — after a terminal outcome, `CredentialStore.current()` is nil.
- [ ] **Step 2: Run** `swift test` — Expected: FAIL.
- [ ] **Step 3: Implement** the actor. actor isolation provides single-active + dedup. Generate one `attemptId: UUID` per confirm call; guard a `activeAttempt` field; on submit throw, call `getResult`; map snapshots; clear credentials on any terminal/dismiss.
- [ ] **Step 4: Run** `swift test` — Expected: PASS.
- [ ] **Step 5: Commit** `git commit -m "feat: CheckoutController orchestration and invariants"`

---

## Task 7: Result polling (backoff, lifecycle-aware)

**Files:**
- Create: `Sources/SunbayCheckout/Core/ResultPoller.swift`
- Modify: `Sources/SunbayCheckout/Core/CheckoutController.swift` (use poller for pending→terminal)
- Test: `Tests/SunbayCheckoutTests/Core/ResultPollerTests.swift`

**Interfaces:**
- Produces: `actor ResultPoller { init(service: PaymentService, config: PollConfig = .default); func pollUntilTerminal(sessionId: String) async -> PaymentSnapshot }`; `struct PollConfig { initial: 1s, max: 5s, overallLimit: ~90s }`. On reaching the limit while still non-terminal, return the latest non-terminal snapshot (controller maps to `unknown`). A injectable `clock`/`sleep` makes tests deterministic.

- [ ] **Step 1: Write the failing tests** — `getResult` returns `I,I,S` across calls → poller resolves `S`; always-`I` with limit reached → returns last `I` snapshot; backoff schedule respected (assert recorded sleep intervals via injected sleeper).
- [ ] **Step 2: Run** `swift test` — Expected: FAIL.
- [ ] **Step 3: Implement** the poller with injected sleep; wire controller to poll when a submit/getResult yields a non-terminal `I`.
- [ ] **Step 4: Run** `swift test` — Expected: PASS.
- [ ] **Step 5: Commit** `git commit -m "feat: result poller with backoff"`

---

## Task 8: ActionHandler (requiresAction dispatch)

**Files:**
- Create: `Sources/SunbayCheckout/Core/ActionHandler.swift`
- Test: `Tests/SunbayCheckoutTests/Core/ActionHandlerTests.swift`

**Interfaces:**
- Consumes: `PaymentAction` (Task 3).
- Produces:
  - `protocol ActionHandling: Sendable { func handle(_ action: PaymentAction, sessionId: String) async -> ActionResult }`
  - `enum ActionResult: Sendable { case pending; case failed(CheckoutError) }`
  - `struct ActionHandler: ActionHandling` — `redirect` → open via an injected `webAuthOpener` (protocol wrapping `ASWebAuthenticationSession`) then return `.pending`; `qrCode`/`showContent`/`unknown` → `.failed(UNSUPPORTED_CAPABILITY)`.
  - `protocol WebAuthOpening: Sendable { func open(_ url: URL) async }` (real impl in Task 11 uses ASWebAuthenticationSession; tests inject a spy).

- [ ] **Step 1: Write the failing tests** — `redirect` → opener called with the url, result `.pending`; `qrCode` → `.failed` with code `UNSUPPORTED_CAPABILITY`, opener not called; `unknown` → `.failed`.
- [ ] **Step 2: Run** `swift test` — Expected: FAIL.
- [ ] **Step 3: Implement** `ActionHandler` over `WebAuthOpening`. No UIKit import here (opener is a protocol).
- [ ] **Step 4: Run** `swift test` — Expected: PASS.
- [ ] **Step 5: Commit** `git commit -m "feat: requiresAction dispatch (redirect/unsupported)"`

---

## Task 9: WalletAuthorizer (PassKit) + public configuration/entry

**Files:**
- Create: `Sources/SunbayCheckout/Core/WalletAuthorizer.swift`
- Create: `Sources/SunbayCheckout/Public/CheckoutConfiguration.swift`
- Create: `Sources/SunbayCheckout/Public/SunbayCheckout.swift` (entry; distinct from the umbrella version file — rename umbrella to `Version.swift` in Task 1 if needed)
- Test: `Tests/SunbayCheckoutTests/Core/WalletAuthorizerTests.swift`

**Interfaces:**
- Produces:
  - `public struct CheckoutConfiguration: Sendable { public enum Environment { case test, production }; environment, applePayMerchantId: String?, appearance: Appearance?, locale: String? }`
  - `public final class SunbayCheckout { public init(configuration: CheckoutConfiguration) }` — builds a controller factory; resolves merchant id as `configuration.applePayMerchantId ?? session.walletMerchantId`.
  - `protocol WalletAuthorizing: Sendable { func canMakePayments() -> Bool; func authorize(amount: Amount, merchantId: String) async throws -> Data }` + `struct WalletAuthorizer: WalletAuthorizing` over PassKit.
- Consumes: `Amount` (Task 2).

- [ ] **Step 1: Write the failing tests** — merchant-id resolution precedence (config over session); `CheckoutConfiguration` stores values; `canMakePayments` is callable (behavior device-dependent — assert it returns a Bool without throwing). PassKit token flow itself is verified by the real-device probe (Task 14), not unit tests.
- [ ] **Step 2: Run** `swift test` — Expected: FAIL.
- [ ] **Step 3: Implement** the configuration, entry, and a PassKit-backed authorizer behind `WalletAuthorizing`.
- [ ] **Step 4: Run** `swift test` — Expected: PASS.
- [ ] **Step 5: Commit** `git commit -m "feat: wallet authorizer and public configuration/entry"`

---

## Task 10: CardField (secure native card inputs)

**Files:**
- Create: `Sources/SunbayCheckout/UI/CardField/CardField.swift`
- Create: `Sources/SunbayCheckout/UI/CardField/CardFieldSecurity.swift` (the per-field config in one place)
- Test: `Tests/SunbayCheckoutTests/UI/CardFieldSecurityTests.swift`

**Interfaces:**
- Produces: a `UIView` collecting PAN/expiry/CVV and exposing a validated `CardInput`; plus `enum CardFieldSecurity { static func apply(toPAN:expiry:cvv: UITextField) }` applying the spec §5.3.1 rules.
- Consumes: `CardInput` (Task 4).

- [ ] **Step 1: Write the failing test** (assert the security config, which is unit-testable without rendering):

```swift
func test_cardFieldSecurity_disablesKeyboardLearning_andCVVHasNoContentType() {
    let pan = UITextField(); let exp = UITextField(); let cvv = UITextField()
    CardFieldSecurity.apply(toPAN: pan, expiry: exp, cvv: cvv)
    for f in [pan, exp, cvv] {
        XCTAssertEqual(f.autocorrectionType, .no)
        XCTAssertEqual(f.spellCheckingType, .no)
        XCTAssertEqual(f.smartDashesType, .no)
    }
    XCTAssertEqual(pan.textContentType, .creditCardNumber)
    XCTAssertNil(cvv.textContentType)         // CVV never autofilled
    XCTAssertEqual(pan.keyboardType, .asciiCapableNumberPad)
}
```

- [ ] **Step 2: Run** `swift test` — Expected: FAIL.
- [ ] **Step 3: Implement** `CardFieldSecurity.apply` per spec §5.3.1, then the `CardField` view using it; expose assembled `CardInput`. Plaintext stays in the field + the returned struct only.
- [ ] **Step 4: Run** `swift test` — Expected: PASS.
- [ ] **Step 5: Commit** `git commit -m "feat: secure native card field"`

---

## Task 11: ApplePayButton (L3) + real WebAuth opener

**Files:**
- Create: `Sources/SunbayCheckout/UI/Wallet/ApplePayButton.swift`
- Create: `Sources/SunbayCheckout/UI/Wallet/WebAuthOpener.swift` (ASWebAuthenticationSession impl of `WebAuthOpening`)
- Test: `Tests/SunbayCheckoutTests/UI/ApplePayButtonTests.swift`

**Interfaces:**
- Produces:
  - `public final class ApplePayButton: UIControl { public init(checkout: SunbayCheckout, sessionId: String, style: ApplePayButtonStyle = .automatic); public var isAvailable: Bool { get }; public var onAvailabilityChange: ((Bool) -> Void)?; public var onResult: ((CheckoutOutcome) -> Void)? }`
  - `struct WebAuthOpener: WebAuthOpening` using `ASWebAuthenticationSession` with the session returnUrl scheme.
- Consumes: `SunbayCheckout` (Task 9), `CheckoutController` (Task 6), `WalletAuthorizing` (Task 9), `CheckoutOutcome` (Task 2).

- [ ] **Step 1: Write the failing test** — with a controller built over mocks where wallet is available, constructing the button sets `isAvailable == true` and fires `onAvailabilityChange(true)`; tapping drives `onResult` with the mock outcome. (Inject the controller/authorizer mocks via an internal initializer.)
- [ ] **Step 2: Run** `swift test` — Expected: FAIL.
- [ ] **Step 3: Implement** the button (closure events, long-lived control) and the real `WebAuthOpener`.
- [ ] **Step 4: Run** `swift test` — Expected: PASS.
- [ ] **Step 5: Commit** `git commit -m "feat: standalone ApplePayButton (L3) and web-auth opener"`

---

## Task 12: PaymentSheet (L1) + Embedded placeholder

**Files:**
- Create: `Sources/SunbayCheckout/UI/PaymentSheet/PaymentSheet.swift`
- Create: `Sources/SunbayCheckout/UI/PaymentSheet/PaymentSheetViewController.swift`
- Create: `Sources/SunbayCheckout/UI/Embedded/EmbeddedPaymentElement.swift` (reserved: a documented placeholder, not `public`)
- Test: `Tests/SunbayCheckoutTests/UI/PaymentSheetTests.swift`

**Interfaces:**
- Produces:
  - `public final class PaymentSheet { public init(checkout: SunbayCheckout, sessionId: String, customerAccessSecret: String? = nil); @MainActor public func present(from: UIViewController) async -> CheckoutOutcome; public func retrievePayment() async throws -> PaymentSnapshot }`
  - Internally: loads session, lists saved cards when `customerAccessSecret != nil && cofEnabled`, renders new-card form (CardField) + Apple Pay option + saved-card list, drives `CheckoutController.confirm*`.
  - `Embedded/EmbeddedPaymentElement.swift`: an internal stub with a doc comment "L2, planned v2 — not part of the public API"; keeps the directory and reserves the name.
- Consumes: Tasks 2/6/9/10/11.

- [ ] **Step 1: Write the failing tests** (logic-level, over an injected controller mock; full UI verified in the example app, Task 13):
  - `test_present_cofEnabledWithSecret_listsSavedCards` — mock session `cofEnabled=true` + secret → controller.listSavedCards called.
  - `test_present_noSecret_doesNotListSavedCards`.
  - `test_present_resolvesWithControllerOutcome` — controller returns `succeeded` → `present` resolves `succeeded`.
  - Assert `EmbeddedPaymentElement` is **not** `public` (compile-time: referenced only from the test target via `@testable`).
- [ ] **Step 2: Run** `swift test` — Expected: FAIL.
- [ ] **Step 3: Implement** PaymentSheet + its view controller wiring to the controller; add the reserved Embedded stub.
- [ ] **Step 4: Run** `swift test` — Expected: PASS.
- [ ] **Step 5: Commit** `git commit -m "feat: PaymentSheet (L1) with COF saved-card list; reserve Embedded (L2)"`

---

## Task 13: Mock backend + example app

**Files:**
- Create: `Example/SunbayCheckoutDemo/` (minimal Xcode app or SwiftPM executable target) with an in-memory `MockPaymentService`/`MockCofService` exercising new-card, Apple Pay option, and COF select-and-pay.
- Create: `Example/README.md`

**Interfaces:**
- Consumes: the public API only (`SunbayCheckout`, `PaymentSheet`, `ApplePayButton`). Must not import internal types.
- Produces: a runnable demo showing `succeeded/failed/pending/unknown` and COF one-tap pay against mocks; no real backend, no secrets.

- [ ] **Step 1:** Build the mock services returning scripted sessions (incl. `rsaPublicKey` from an in-app test key, `cofEnabled=true`) and results.
- [ ] **Step 2:** Wire a screen: "Pay (sheet)" presents `PaymentSheet`; a separate `ApplePayButton`. Show the returned `CheckoutOutcome`.
- [ ] **Step 3: Verify** the app builds and runs on a simulator; present sheet → new-card and saved-card paths resolve to the scripted outcomes.
- [ ] **Step 4: Commit** `git commit -m "feat: mock-backed example app"`

---

## Task 14: Apple Pay real-device probe

**Files:**
- Create: `Example/ApplePayProbe/` — standalone probe (independent of the SDK target) that runs capability check → PassKit sheet → token, with placeholder merchant/gateway params, TEST env, redacted token diagnostics only.
- Create: `Example/ApplePayProbe/README.md` (entitlement/merchant-id setup notes; no real certificates committed)

**Interfaces:**
- Consumes: PassKit directly (this is a probe, not an SDK consumer).
- Produces: evidence that the device can drive the Apple Pay sheet and obtain a token. No backend call, no raw token logged.

- [ ] **Step 1:** Implement capability detection + `PKPaymentAuthorizationController` flow; show redacted token presence only.
- [ ] **Step 2: Verify** on a real device that capability → sheet → token works (or reaches the expected cancel/no-card branch). Document the result in the README.
- [ ] **Step 3: Commit** `git commit -m "chore: Apple Pay real-device probe"`

---

## Final verification (whole branch)

- [ ] `swift test` — all tests pass.
- [ ] Grep guard: no `print(`/`os_log` carrying card/token/secret identifiers in `Sources/`.
- [ ] Public-API audit: only the intended symbols are `public` (Configuration, SunbayCheckout, PaymentSheet, ApplePayButton, CheckoutOutcome, CheckoutError, SavedCard, PaymentSnapshot, Amount, TxnStatus, Appearance). `EmbeddedPaymentElement` and all Core services are **not** public.
- [ ] Example app builds; Apple Pay probe result recorded.
