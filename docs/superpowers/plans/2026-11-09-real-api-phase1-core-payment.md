# Real API Integration, Phase 1 (core payment path) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** A host app can pay with a new card or Apple Pay against the real `dev` backend through `SunbayCheckout(configuration:)`, with sessions created by a local Node dev server.

**Architecture:** One internal `SunbayAPIClient` (Foundation only) talks to a single HPP origin per environment and unwraps the `{code,msg,data,traceId}` envelope. `HTTPPaymentService` implements the existing `PaymentService` protocol on top of it, so Core and UI change only where the real contract forces it. A dependency-free Node server (`Example/DevServer`) creates sessions for the Example app and for opt-in real-API tests.

**Tech Stack:** Swift 5.9, URLSession, XCTest, Node 20.6+ (no dependencies), Tuist Example app.

**Spec:** `docs/superpowers/specs/2026-11-09-real-api-integration-design.md` (this plan covers its §5.1, §5.2, §5.3, §5.4, §5.5 phase 1, §5.7). Backend contracts: `docs/api/checkout-api.json`, `docs/api/checkout.openapi.json`.

## Global Constraints

- Swift only; **all code, comments, strings, test names, commit messages and docs in English** (`AGENTS.md` §2).
- Core and the new client import no UIKit/PassKit. iOS target stays 15.
- No `baseURL` in public API. Hosts per environment (verify before release): dev `https://checkout.sunbay-dev.com`, test `https://checkout.sunbay-uat.us`, production `https://checkout.sunbay.us`. Routes under `/api/checkout/web/...`.
- Envelope success is `code == "0"` (string). Backend `txnStatus` is `S` / `F` / `R` only.
- Card values, wallet tokens, `customerAccessSecret`, `checkoutClientSecret`, request/response bodies never reach logs, error messages or public callbacks.
- A lost or ambiguous submit response triggers at most **one** result query, then `unknown`; never `failed`, never a resubmit (`AGENTS.md` §2.5).
- Create-session body for native: `sessionType: "sdk"`, `customerId`, `supportStoreCard: true`.
- Commit steps are checkpoints: run them **only if the user has asked for commits**, with `git add <exact files>` (never `git add .`). Develop on `feature/real-api-phase1`, never on `main`.
- Out of scope here (later phases): `HTTPCofService`, `CardOnFileOptions`, address, card rules/BIN, billing/shipping address in the submit body. Phase-1 sandbox sessions are created with `collectBillingAddress: false`.

## Review Focus

1. A WAF/proxy returns an HTML page or a 502/504 with no envelope: must become a `.network` `CheckoutError`, never a crash; on submit it counts as ambiguous.
2. A session id containing `/`, `?` or spaces: must be percent-encoded in the path, never alter the route.
3. `HTTPPaymentService` remembers the last `action` for `PaymentActionProviding`: a stale action from an earlier attempt must never be used for a later `R`.
4. `expiresAt` arrives as `2026-11-09T10:00:00+0800`, `...+08:00`, or with fractional seconds: all must parse.
5. `totalAmount` is non-integral, missing, or `paymentMethods` has only unknown methods, or `rsaPublicKey` is null: decoding or the card path degrades with a typed error, no crash.

---

### Task 1: Branch and Node dev server

**Files:**
- Modify: `.gitignore`
- Create: `Example/DevServer/session.mjs`, `Example/DevServer/server.mjs`, `Example/DevServer/.env.example`, `Example/DevServer/README.md`, `Example/DevServer/test/session.test.mjs`
- Local only, git-ignored: `Example/DevServer/.env.local`

**Interfaces:**
- Produces: HTTP `POST /api/create-session` body `{amount?:number (major units), items?, currency?, collectBillingAddress?, collectShippingAddress?}` returning JSON `{sessionId, checkoutClientSecret, customerAccessSecret|null}`; `GET /healthz` returning `{ok, hasCredentials, warning}`; `session.mjs` exports `buildCreateSessionPayload(input, config, now) -> object` and `createSession(input)`.

- [ ] **Step 1:** If the current branch is `main`, run `git switch -c feature/real-api-phase1`. Add to `.gitignore`: `Example/DevServer/.env.local` and `Example/DevServer/node_modules/`. Verify with `git check-ignore -v Example/DevServer/.env.local` (prints the rule).
- [ ] **Step 2: Write the failing test** `Example/DevServer/test/session.test.mjs` (`node:test`). Cases for `buildCreateSessionPayload({amount: 9.99}, {appId:'a', merchantId:'m', currency:'USD', customerId:'cust-1'}, 1700000000000)`: `sessionType === 'sdk'`; `customerId === 'cust-1'`; `supportStoreCard === true`; `amount.orderAmount === 999`; `amount.taxAmount === Math.round(999*0.08)`; `productList[0].amount === 999 && num === 1`; `collectBillingAddress === false`; `transactionRequestId` and `referenceOrderId` start with `IOS`; an explicit `items` array wins over `amount`.
- [ ] **Step 3:** Run `node --test Example/DevServer/test/`. Expected: FAIL (module missing).
- [ ] **Step 4: Implement** `session.mjs` by copying and adapting `/Users/sm4267/workspace/web/checkout-sdk-web/js/example/server/session.mjs` (same open-platform call: `POST {OPEN_API_URL}/v1/checkout/create-session`, `Authorization: Bearer API_KEY`, `X-Client-Request-Id`, `X-Timestamp`). Changes: extract the pure `buildCreateSessionPayload`; payload gains `customerId` (from `CUSTOMER_ID`, default `sunbay-ios-dev-customer`), `supportStoreCard: true`, `sessionType: 'sdk'`, `collectBillingAddress` default `false`; `createSession` returns `{sessionId, checkoutClientSecret, customerAccessSecret}` from the upstream `data`. Implement `server.mjs` after the JS example's `server.mjs` minus static hosting: only `POST /api/create-session` (503 with a clear message when credentials are absent) and `GET /healthz`; bind `HOST` (default `127.0.0.1`), `PORT` (default `8095`). It prints this red banner at startup and returns it as `warning` from `/healthz`: `DEV ONLY. This server holds merchant API credentials. In production, create the session in YOUR backend; never put the API key in an app.` Put the same text at the top of both `.mjs` files and the README.
- [ ] **Step 5:** `.env.example` lists `API_KEY`, `APP_ID`, `MERCHANT_ID`, optional `CUSTOMER_ID`, `OPEN_API_URL`, `CURRENCY`, `PORT`, `HOST`. Run `cp /Users/sm4267/workspace/web/checkout-sdk-web/js/example/.env.local Example/DevServer/.env.local` (do not print it).
- [ ] **Step 6:** Run `node --test Example/DevServer/test/` (PASS). Then `node Example/DevServer/server.mjs &`, `curl -s http://127.0.0.1:8095/healthz` (expect `"hasCredentials":true` and the warning), `curl -s -X POST http://127.0.0.1:8095/api/create-session -H 'content-type: application/json' -d '{}'` (expect `sessionId` starting with a session prefix, non-empty `checkoutClientSecret` starting `ccs_`, `customerAccessSecret` starting `cas_`). Stop the server. If `customerAccessSecret` is null or the call fails, stop and report the upstream message to the user (backend rename or credentials issue).
- [ ] **Step 7: Commit** `Example/DevServer/*` (not `.env.local`) and `.gitignore`: `feat(devserver): add Node dev session server for Example and real-API tests`.

---

### Task 2: Endpoints and API client

**Files:**
- Create: `Sources/SunbayCheckout/Core/Network/SunbayEndpoints.swift`, `Sources/SunbayCheckout/Core/Network/SunbayAPIClient.swift`
- Test: `Tests/SunbayCheckoutTests/Core/SunbayEndpointsTests.swift`, `Tests/SunbayCheckoutTests/Core/SunbayAPIClientTests.swift`, `Tests/SunbayCheckoutTests/Support/StubURLProtocol.swift`

**Interfaces:**
- Produces:
  - `enum SunbayEndpoints { enum Route: Equatable { case loadSession(id: String), submitPayment, paymentResult(sessionId: String) }; static func origin(for: CheckoutConfiguration.Environment) -> URL; static func url(for: Route, environment: CheckoutConfiguration.Environment) -> URL }`
  - `struct SunbayAPIClient: Sendable { init(environment: CheckoutConfiguration.Environment, locale: String?, session: URLSession = SunbayAPIClient.makeSession()); static func makeSession() -> URLSession; func post<Body: Encodable & Sendable, Response: Decodable & Sendable>(_ route: SunbayEndpoints.Route, body: Body, timeout: TimeInterval = 15) async throws -> Response }`
  - Every failure is thrown as `CheckoutError`. Transport error, timeout, non-2xx without a usable envelope, unparsable body, missing `data` on success: category `.network`, codes `NETWORK_UNAVAILABLE` / `HTTP_<status>` / `INVALID_RESPONSE`. Envelope `code != "0"`: category `.payment`, `code`, `message = msg`, `traceId` from the envelope.
  - `StubURLProtocol` test helper: `static var handler: ((URLRequest) throws -> (HTTPURLResponse, Data))?`, plus `static func session() -> URLSession`.

- [ ] **Step 1: Write failing tests** `SunbayEndpointsTests`: `url(for: .loadSession(id: "ab"), environment: .dev)` equals `https://checkout.sunbay-dev.com/api/checkout/web/session/ab`; `.submitPayment` on `.production` equals `https://checkout.sunbay.us/api/checkout/web/payment/submit`; `.paymentResult(sessionId:)` on `.test` ends `/api/checkout/web/payment/result/<id>` under `https://checkout.sunbay-uat.us`; `loadSession(id: "a/b?c d")` yields path containing `a%2Fb%3Fc%20d` and no extra path component.
- [ ] **Step 2:** Tests in `SunbayAPIClientTests` (via `StubURLProtocol`): success envelope `{"code":"0","msg":"ok","data":{"x":1}}` decodes `data`; request is `POST` with `Content-Type: application/json` and `Accept-Language: zh-CN` when locale is `zh-CN`, plus header `X-Sunbay-SDK` starting `ios/`; envelope `{"code":"CHECKOUT_EXPIRED","msg":"expired","traceId":"t1"}` throws `CheckoutError(code:"CHECKOUT_EXPIRED", category:.payment, traceId:"t1")`; HTTP 502 with HTML body throws `.network` with code `HTTP_502`; HTTP 200 with HTML body throws `.network` `INVALID_RESPONSE`; `URLError(.timedOut)` and `.notConnectedToInternet` throw `.network` `NETWORK_UNAVAILABLE`; thrown `CheckoutError.message` for network failures contains neither the request URL nor body text (assert it does not contain the session id used in the test).
- [ ] **Step 3:** Run `swift test --filter 'SunbayEndpointsTests|SunbayAPIClientTests'`. Expected: FAIL (types missing).
- [ ] **Step 4: Implement** the two files. `makeSession()` uses `URLSessionConfiguration.ephemeral` with `urlCache = nil`, `httpCookieStorage = nil`, `requestCachePolicy = .reloadIgnoringLocalCacheData`, `waitsForConnectivity = false`. Percent-encode ids with a character set that excludes `/ ? # %` and space. Add `SDKInfo.version` (a `static let` string) if no version constant exists, used in `X-Sunbay-SDK: ios/<version>`. Error messages are fixed generic strings; never interpolate the URL, body, or `URLError.localizedDescription`.
- [ ] **Step 5:** Run the same filter. Expected: PASS. Then `swift build`. Expected: success.
- [ ] **Step 6: Commit** the five files: `feat(network): add SunbayEndpoints and envelope-aware API client`.

---

### Task 3: Real contract decoding

**Files:**
- Modify: `Sources/SunbayCheckout/Core/ContractDecoding.swift`, `Tests/SunbayCheckoutTests/Core/ContractCodableTests.swift`

**Interfaces:**
- Consumes: `CheckoutSession`, `PaymentSnapshot`, `TxnStatus`, `PaymentAction`, `ResultEnvelope` (unchanged).
- Produces: `ContractDecoding.SessionWire` and `ContractDecoding.ResultWire` become `internal` `Decodable` types with `func toSession() throws -> CheckoutSession` / `func toEnvelope() throws -> ResultEnvelope` (so `SunbayAPIClient.post` can decode them directly); `decodeSession(from:)` and `decodeResult(from:)` stay as thin wrappers.
- Wire facts: session `data` has `sessionId`, `currency`, `totalAmount` (minor units, integer), `expiresAt`, `merchantName`, `rsaPublicKey?`, `supportStoreCard?` (absent means `true`), `paymentMethods[{method,type}]`. Submit and result `data` have `txnId?`, `txnStatus` (`S`/`F`/`R`, `I` tolerated), `sessionId`, `action?{type,redirectUrl?}`, `failureReason?`, `resultUrl?`.

- [ ] **Step 1: Update failing tests** in `ContractCodableTests`: session JSON without `cofEnabled` and with `"supportStoreCard": false` gives `cofEnabled == false`; absent `supportStoreCard` gives `true`; `expiresAt` values `2026-11-09T10:00:00+08:00`, `2026-11-09T10:00:00+0800`, `2026-11-09T10:00:00.123+08:00` all parse to the same instant (±0.123 s); `totalAmount: 1050` gives `Amount(minorUnits: 1050, ...)`; `totalAmount: 10.5` throws `DecodingError`; `paymentMethods` with only `{"method":"MYSTERY","type":"APM"}` yields an empty `methods` set without throwing; `rsaPublicKey: null` yields `nil`; result JSON with `txnStatus:"R"` and `action:{"type":"redirect","redirectUrl":"https://x.test/p"}` maps to `.redirect`; `txnStatus:"Z"` throws.
- [ ] **Step 2:** Run `swift test --filter ContractCodableTests`. Expected: FAIL.
- [ ] **Step 3: Implement** the changes: drop the `cofEnabled` wire field, read `supportStoreCard` (default true), widen the ISO-8601 parser with a fallback `DateFormatter` (`en_US_POSIX`, `yyyy-MM-dd'T'HH:mm:ssZ` and the fractional variant) for offsets without a colon, decode `totalAmount` as `Decimal` and require it to be integral.
- [ ] **Step 4:** Run `swift test --filter ContractCodableTests`. Expected: PASS.
- [ ] **Step 5: Commit**: `feat(contract): decode the real session and payment responses`.

---

### Task 4: SubmitRequest reshape, credentials, controller

**Files:**
- Modify: `Sources/SunbayCheckout/Core/PaymentService.swift`, `Core/CredentialStore.swift`, `Core/CheckoutController.swift`, `UI/PaymentSheet/PaymentSheet.swift`, `Sources/SunbayCheckoutTestSupport/ScriptablePaymentService.swift` (if it reads removed fields), existing tests that construct `SubmitRequest`/`Consent`
- Test: `Tests/SunbayCheckoutTests/Core/CheckoutControllerTests.swift`, `Tests/SunbayCheckoutTests/Core/CredentialStoreTests.swift`, `Tests/SunbayCheckoutE2ETests/CheckoutInvariantsE2ETests.swift`

**Interfaces:**
- Produces:
  - `SubmitRequest(sessionId:paymentMethod:attemptId:cardEncryptedData:walletToken:savedCardId:storeCard:customerAccessSecret:checkoutClientSecret:)` with all but the first three defaulted to `nil`; `Consent` and the `paymentMethodId`/`savePaymentMethod`/`consent` fields are **removed**. `SubmitRequest` conforms to `CustomDebugStringConvertible` and prints no secret, token or ciphertext.
  - `CredentialStore`: `hold(checkoutClientSecret:)`, `currentCheckoutClientSecret() -> String?`; `clear()` clears both secrets.
  - `CheckoutController.start(sessionId:customerAccessSecret:checkoutClientSecret:)` (last param `String? = nil`); `confirmNewCard(_:save:)` (no `consent`); `confirmSavedCard(paymentMethodId:)` keeps its name and UI wiring but builds `paymentMethod: "TOKEN"`, `savedCardId`, and `customerAccessSecret` from the store.
  - Submit error semantics in `submitAndResolve`: a thrown `CheckoutError` whose category is not `.network` is a definite rejection and returns `.failed(txnId: nil, error: thatError)` after `terminalCleanup()` with **no** result query; any other thrown error (including `.network`) keeps the existing single `getResult` then `.unknown`.
  - `storeCard` is sent as `true` only when `save == true && session.cofEnabled`, otherwise `nil`.

- [ ] **Step 1: Write failing tests** in `CheckoutControllerTests` (using the existing mock service): new-card submit with `save: true` on a `cofEnabled == false` session leaves `storeCard == nil`; with a `cofEnabled == true` session and `save: true` gives `storeCard == true`; submit carries `checkoutClientSecret` and, for saved card, `paymentMethod == "TOKEN"`, `savedCardId`, `customerAccessSecret`; a service that throws `CheckoutError(code:"PAYMENT_METHOD_NOT_ALLOWED", category:.payment)` yields `.failed` with that code and `getResult` is never called; a service that throws `URLError(.timedOut)` yields `.unknown` after exactly one `getResult` call; `String(reflecting: SubmitRequest(... cardEncryptedData:"CIPHER", checkoutClientSecret:"ccs_x" ...))` contains neither value. In `CredentialStoreTests`: `clear()` empties both secrets.
- [ ] **Step 2:** Run `swift test --filter 'CheckoutControllerTests|CredentialStoreTests'`. Expected: FAIL (compile errors on new signatures).
- [ ] **Step 3: Implement** the interface block above. In `PaymentSheet`, remove the `Consent(version:)` construction and pass `save` only; add `checkoutClientSecret: String?` handling in Task 6, not here (keep this task compiling by passing `nil`). Fix every compile error in `Sources/`, `Tests/`, and `Example/` call sites flagged by `swift build` / `swift build --build-tests`.
- [ ] **Step 4:** Run `swift test`. Expected: all pass.
- [ ] **Step 5: Commit** touched files: `refactor(core): align SubmitRequest and controller with the real submit contract`.

---

### Task 5: HTTPPaymentService and device info

**Files:**
- Create: `Sources/SunbayCheckout/Core/Network/HTTPPaymentService.swift`, `Sources/SunbayCheckout/Core/Network/DeviceInfoCollector.swift`
- Test: `Tests/SunbayCheckoutTests/Core/HTTPPaymentServiceTests.swift`, `Tests/SunbayCheckoutTests/Core/DeviceInfoCollectorTests.swift`

**Interfaces:**
- Consumes: `SunbayAPIClient.post`, `ContractDecoding.SessionWire/ResultWire`, `CredentialStore.currentCheckoutClientSecret()`, `SubmitRequest`, `PaymentActionProviding`.
- Produces:
  - `struct UserDeviceInfoWire: Encodable, Sendable` with keys `deviceType, deviceModel, deviceOs, deviceOsVersion, deviceResolution, screenWidth, screenHeight, colorDepth, timeZoneOffset, language` (all `String?`; no `ip`, no `userAgent`, no browser fields).
  - `enum DeviceInfoCollector { static func collect(screen: (width: Int, height: Int, scale: Double)?) -> UserDeviceInfoWire }` (Foundation/Darwin only; `deviceModel` from `utsname.machine`, `deviceOs: "iOS"`, `deviceType: "mobile"`).
  - `final class HTTPPaymentService: PaymentService, PaymentActionProviding, @unchecked Sendable { init(client: SunbayAPIClient, credentials: CredentialStore, deviceInfo: @escaping @Sendable () -> UserDeviceInfoWire?) }` using an `NSLock`-guarded `lastAction`.
  - Routes and bodies: `loadSession` -> `POST session/{id}` body `{checkoutClientSecret}` (throws `CheckoutError(code:"CHECKOUT_CLIENT_SECRET_MISSING", category:.configuration)` when no secret is held); `submit` -> `POST payment/submit`; `getResult` -> `POST payment/result/{sessionId}` with body `{}`.
  - Submit body keys: `sessionId`, `paymentMethod`, `cardEncryptedData` (ciphertext for CARD; wallet token as a UTF-8 string of the token JSON for `APPLE_PAY`, via one function `WalletTokenEncoder.encode(_ token: Data) -> String` so the open Apple Pay format question changes one place), `storeCard`, `savedCardId`, `customerAccessSecret`, `checkoutClientSecret`, `userDeviceInfo`. Nil values are omitted from the JSON.

- [ ] **Step 1: Write failing tests** (client built on `StubURLProtocol`, `.dev` environment): `loadSession("s1")` sends body `{"checkoutClientSecret":"ccs_x"}` to `/api/checkout/web/session/s1` and returns a `CheckoutSession` with `cofEnabled` from `supportStoreCard`; with no held secret it throws the configuration error and sends no request; a new-card submit body contains `paymentMethod:"CARD"`, `cardEncryptedData:"CIPHER"`, `checkoutClientSecret`, a `userDeviceInfo` object, and no `savedCardId`/`customerAccessSecret` keys; a saved-card submit contains `paymentMethod:"TOKEN"`, `savedCardId`, `customerAccessSecret`; an Apple Pay submit contains `paymentMethod:"APPLE_PAY"` and `cardEncryptedData` equal to the token JSON string; response `txnStatus:"S"` returns a `.succeeded` snapshot with `txnId`; a response `R` with a redirect action makes `actionForLatestRequiresAction()` return `.redirect(url)`; **after that, a second submit that answers `S` makes `actionForLatestRequiresAction()` return `nil`** (stale action cleared at the start of every submit); `getResult` posts to `payment/result/s1`. In `DeviceInfoCollectorTests`: `collect(screen: (390, 844, 3))` gives `screenWidth == "1170"`, `screenHeight == "2532"`, `deviceOs == "iOS"`, non-empty `language`, `timeZoneOffset` equals `String(-TimeZone.current.secondsFromGMT()/60)`.
- [ ] **Step 2:** Run `swift test --filter 'HTTPPaymentServiceTests|DeviceInfoCollectorTests'`. Expected: FAIL.
- [ ] **Step 3: Implement** both files to the interfaces above. `HTTPPaymentService` must never include request or response bodies in thrown errors or any log.
- [ ] **Step 4:** Run the same filter. Expected: PASS. Run `swift build`. Expected: success.
- [ ] **Step 5: Commit**: `feat(payment): add HTTPPaymentService against the real checkout API`.

---

### Task 6: Default wiring and public entry points

**Files:**
- Modify: `Sources/SunbayCheckout/Public/SunbayCheckout.swift`, `Sources/SunbayCheckout/UI/PaymentSheet/PaymentSheet.swift`, every other entry that calls `controller.start(` (find with `grep -rn "\.start(sessionId" Sources`, includes the Apple Pay button entry), `Sources/SunbayCheckout/Core/UnconfiguredServices.swift` (keep `UnconfiguredCofService`; delete `UnconfiguredPaymentService` if unused)
- Test: `Tests/SunbayCheckoutTests/Public/` (existing `SunbayCheckout` tests) plus a new `SunbayCheckoutDefaultWiringTests.swift`

**Interfaces:**
- Produces:
  - `SunbayCheckout.init(configuration:)` now builds `HTTPPaymentService` per controller (so it shares each sheet's `CredentialStore`) with a `SunbayAPIClient(environment: configuration.environment, locale: configuration.locale)`; the cof service stays `UnconfiguredCofService` in this phase, so saved cards degrade to none. The injecting initializer keeps working unchanged. Implement through an internal `serviceFactory: (CredentialStore) -> (any PaymentService, any CofService)`; the injecting init wraps its fixed services.
  - `PaymentSheet.init(checkout:sessionId:customerAccessSecret:checkoutClientSecret:)` and the equivalent for every other public entry: new parameter `checkoutClientSecret: String? = nil` (documented as issued by the host backend, memory only, never logged) passed to `controller.start`.

- [ ] **Step 1: Write failing tests**: `SunbayCheckout(configuration:)` + `makeController(credentials:actionHandler:)` returns a controller whose service is an `HTTPPaymentService` (assert via an internal accessor or by stubbing `URLProtocol` through an injected session and observing the host `checkout.sunbay-dev.com` for `.dev`); two controllers built from the same checkout use different `CredentialStore` instances; the injecting init still uses the injected mock.
- [ ] **Step 2:** Run `swift test --filter SunbayCheckoutDefaultWiringTests`. Expected: FAIL.
- [ ] **Step 3: Implement** the wiring. When the screen metrics are available (`#if canImport(UIKit)`), pass `UIScreen.main.bounds`/`scale` into `DeviceInfoCollector.collect(screen:)` from `SunbayCheckout`, not from Core.
- [ ] **Step 4:** Run `swift test` (all PASS) and `swift build --build-tests`.
- [ ] **Step 5: Commit**: `feat(public): default to the real backend and accept checkoutClientSecret`.

---

### Task 7: DevSessionClient, real-API tests, runner script

**Files:**
- Create: `Sources/SunbayCheckoutTestSupport/DevSessionClient.swift`, `Tests/SunbayCheckoutRealAPITests/RealAPIPaymentTests.swift`, `scripts/run-dev-e2e.sh`
- Modify: `Package.swift` (new test target `SunbayCheckoutRealAPITests`, path `Tests/SunbayCheckoutRealAPITests`, depends on `SunbayCheckout` and `SunbayCheckoutTestSupport`)

**Interfaces:**
- Produces: `public struct DevSession: Sendable { public let sessionId: String; public let checkoutClientSecret: String; public let customerAccessSecret: String? }`; `public struct DevSessionClient: Sendable { public init(serverURL: URL); public func createSession(amountMajorUnits: Double = 0.01, collectBillingAddress: Bool = false) async throws -> DevSession }` posting to `{serverURL}/api/create-session`. Test-support doc comment carries the DEV ONLY warning from Task 1.
- Real-API tests read `SUNBAY_DEV_SERVER_URL`; every test starts with `try XCTSkipIf` when it is unset, and also skips unless the configured environment is `.dev` or `.test`.

- [ ] **Step 1: Write the tests** `RealAPIPaymentTests`: (a) `testLoadSessionAgainstDev`: create a 1.05 session via `DevSessionClient`, build `HTTPPaymentService` with `SunbayAPIClient(environment: .dev, ...)` and a `CredentialStore` holding the secret, `loadSession` returns `id == sessionId`, non-nil `rsaPublicKey`, `methods` contains `.card`, `cofEnabled == true`, and `amount.minorUnits` equals the upstream total for 1.05 major units plus tax (assert the **unit**: this is the check that settles the minor-vs-major ambiguity in the API doc; if it fails, stop and tell the user); (b) `testExpiredOrUnknownSessionIsRejected`: `loadSession("does-not-exist")` throws a `CheckoutError` (not `.network`); (c) `testNewCardPaymentReachesTerminalState`: requires env `SUNBAY_TEST_CARD_NUMBER`, `SUNBAY_TEST_CARD_EXPIRY_MM`, `SUNBAY_TEST_CARD_EXPIRY_YYYY`, `SUNBAY_TEST_CARD_CVV` (skip if missing), runs `CheckoutController.start` then `confirmNewCard`, expects `.succeeded` and, immediately after, `retrievePayment` snapshot is `.succeeded` with the same `txnId`.
- [ ] **Step 2:** Implement `DevSessionClient`. Add the target to `Package.swift`. Run `swift build --build-tests`. Expected: success. Run `swift test --filter RealAPIPaymentTests`. Expected: tests **skipped**, suite green.
- [ ] **Step 3:** Write `scripts/run-dev-e2e.sh` (bash, `set -euo pipefail`): start `node Example/DevServer/server.mjs` in the background on a free port, trap-kill it on exit, poll `/healthz` for up to 10 s, then run `SUNBAY_DEV_SERVER_URL=http://127.0.0.1:$PORT swift test --filter SunbayCheckoutRealAPITests`; exit non-zero if the server never became healthy or `hasCredentials` is false. Make it executable.
- [ ] **Step 4:** Run `scripts/run-dev-e2e.sh`. Expected: (a) and (b) pass against the dev backend; (c) passes if the card env vars are provided, otherwise skipped. Report the results to the user, including the observed `totalAmount` unit and whether the dev origin accepts the SDK's requests (a WAF block would show as `HTTP_403`/`INVALID_RESPONSE`).
- [ ] **Step 5: Commit**: `test(real-api): add dev session client, opt-in real-API tests and runner script`.

---

### Task 8: Example app, README warnings, docs

**Files:**
- Modify: `Example/SunbayCheckoutDemo/Sources/DemoSettings.swift`, `DemoRootView.swift` (read them first), `Example/SunbayCheckoutDemo/Project.swift` (Info.plist `NSAppTransportSecurity` -> `NSAllowsLocalNetworking = true`), `Example/README.md`, `docs/product-spec.md` (§2 and §7), `docs/security-and-pci.md`, `docs/real-api-integration-checklist.md`, `AGENTS.md` (rule 7 wording: the SDK now ships real adapters behind protocols); Showcase untouched except hiding any dev-server path behind `#if DEBUG`
- Create: `Sources/SunbayCheckout/Resources/PrivacyInfo.xcprivacy` (declare `NSPrivacyTracking` false, empty tracking domains, no collected data types; add to the `SunbayCheckout` target resources) and update `Package.swift` accordingly

**Interfaces:**
- Consumes: `DevSessionClient`, `SunbayCheckout(configuration:)`, `PaymentSheet(checkout:sessionId:customerAccessSecret:checkoutClientSecret:)`.
- Produces: a "Real (dev server)" mode in the Example settings with an editable server URL (default `http://127.0.0.1:8095`) and environment picker limited to `.dev`/`.test`; a persistent red banner on screens in that mode reading `DEV ONLY: sessions are created by a local dev server that holds your API key. In production, create the session in your own backend.`

- [ ] **Step 1:** Add the mode and banner; on "Pay", call `DevSessionClient.createSession`, then present `PaymentSheet` with `sessionId`, `customerAccessSecret`, `checkoutClientSecret`. Mock mode stays the default so existing Example behavior and localization checks are unchanged. Regenerate with `tuist generate` and build the Example for a simulator (`xcodebuild -workspace Example/SunbayCheckoutDemo/SunbayCheckoutDemo.xcworkspace -scheme SunbayCheckoutDemo -destination 'generic/platform=iOS Simulator' build`). Expected: BUILD SUCCEEDED.
- [ ] **Step 2:** Docs, in English: `Example/README.md` opens with the DEV ONLY warning and how to start the server (`cd Example/DevServer && cp .env.example .env.local && node server.mjs`), a production-integration snippet (host app fetches `{sessionId, checkoutClientSecret, customerAccessSecret?}` from its own backend), and the real-device LAN note (`HOST=0.0.0.0`). `security-and-pci.md` gains: the DevServer warning, the device-info fields sent, and that the SDK now talks to the HPP origin over TLS. `product-spec.md` §7: replace the mock baseline for session, submit and result with the contract in the spec's §5.3; list `checkoutClientSecret` and the new `SubmitRequest`. `real-api-integration-checklist.md` §2: mark Phase 1 items and keep the Apple Pay token format, `paymentMethod` for new cards (`CARD` vs brand), and `sessionType` in submit as open verification items.
- [ ] **Step 3:** Run the full suite once more: `swift test` (all PASS, real-API tests skipped). Then manual check on a simulator: start the dev server, run the Example in Real mode, pay with a test card (expect succeeded) and confirm the banner is visible. Apple Pay needs a real device; if unavailable, say so explicitly rather than claiming it works.
- [ ] **Step 4: Commit** (exact files): `feat(example): real dev-server mode, warnings, docs and privacy manifest`.

---

## Self-review notes

- Spec coverage: §5.1 (Task 2), §5.2 (Task 2), §5.3 rows for saved-card/save-card/wallet/status/client secret/device info (Tasks 3-5; saved-card list and `card/list` are phase 2 by design), §5.4 public API and removals (Tasks 4, 6), §5.5 phase 1 exit (Tasks 7, 8), §5.7 (Tasks 1, 7, 8). Phase 2-4 items are intentionally absent.
- Types used across tasks: `SunbayAPIClient.post`, `SunbayEndpoints.Route`, `HTTPPaymentService.init(client:credentials:deviceInfo:)`, `SubmitRequest` fields, `CredentialStore` secret accessors, and `DevSessionClient.createSession` are defined once and referenced consistently.
- Open verification items (not blockers for coding, flagged inside tasks): totalAmount unit (Task 7a), `paymentMethod` value for new cards, Apple Pay token format, submit `sessionType`, WAF behavior for native clients.
