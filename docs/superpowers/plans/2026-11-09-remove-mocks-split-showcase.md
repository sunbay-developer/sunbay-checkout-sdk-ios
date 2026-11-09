# Remove App Mocks and Split Showcase Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Both demo apps pay only through real dev orders: Showcase lives in its own sibling repo and creates sessions in the app with a test merchant; the Example app keeps only the dev-server path; the SDK repo no longer contains Showcase.

**Architecture:** Showcase is split out with `git subtree split` into `../showcase-ios` and depends on the SDK by local path. A Swift `SessionCreator` (port of `Example/DevServer/session.mjs`) builds the open-platform create-session call from generate-time Tuist environment values. The Example app drops its mock mode and environment picker and always uses `DevSessionClient` plus `SunbayCheckout(configuration:)`.

**Tech Stack:** Swift 5.9, SwiftUI, Tuist, XCTest, git subtree, Node dev server (existing).

**Spec:** `docs/superpowers/specs/2026-11-09-remove-mocks-and-split-showcase-design.md`

## Global Constraints

- English only in all code, comments, strings, test names, commit messages and docs, in both repos (`AGENTS.md` §2).
- Merchant API key, appId, merchant account id and client secrets are never committed, printed, logged, or put in error messages, in either repo. `credentials.env` is git-ignored before it is created.
- Both apps are fixed to `CheckoutConfiguration(environment: .dev)`. The SDK public default stays `.production` (do not change `CheckoutConfiguration`).
- SDK test doubles stay: `Tests/SunbayCheckoutTests/Support/Mock*`, `SunbayCheckoutTestSupport` `Scriptable*` and `DemoSessionFactory`. `swift test` stays offline and green.
- Showcase create-session body: `sessionType: "sdk"`, `customerId`, `supportStoreCard: true`, `collectBillingAddress: false`, `collectShippingAddress: false`, `amount.orderAmount` = cart total in USD minor units, `amount.taxAmount = 0`, `priceCurrency "USD"`, ids `SBC<ms>`.
- SDK repo work on branch `chore/remove-mocks-split-showcase`; `showcase-ios` commits on its local `main`. Commits with exact files only, never `git add .`, never `git add -f`, never push, never add a remote.
- Paths: SDK repo `/Users/sm4267/workspace/web/checkout-sdk-native/ios`; Showcase repo `/Users/sm4267/workspace/web/checkout-sdk-native/showcase-ios`. Simulator destination `id=D8302CDE-6AD6-4593-9A11-6F7BC3C9DB57` (iPhone 17 Pro; the name is ambiguous).

## Review Focus

1. Showcase built without credentials: the app launches; Pay shows the "not configured" message; no crash, no request sent.
2. Upstream create-session fails (`code != "0"`, non-JSON, timeout): a toast with a generic message, `isPresenting` reset, Pay usable again; no key or body in the message.
3. A cart total of 0 or an empty cart: Pay stays disabled (existing guard); no session is created.
4. Example dev server URL invalid or server down: the existing "Invalid server URL" / error message path still works after the mode removal.
5. The split repo builds from a clean checkout next to `ios/` (`tuist generate` from scratch, no stale `Derived/` from the old location).

---

### Task 1: Split Showcase into the sibling repo

**Files:**
- Create (new repo): `/Users/sm4267/workspace/web/checkout-sdk-native/showcase-ios` from the split history
- Modify (new repo): `Project.swift` (`.package(path: "../ios")`, header comment), `README.md`
- Create (new repo): `.gitignore`, `AGENTS.md`

**Interfaces:**
- Produces: a git repo at the sibling path whose root is the former `Showcase/` content with its history; builds against `../ios`.

- [ ] **Step 1:** In the SDK repo run `git subtree split --prefix=Showcase -b showcase-split`; then `git init /Users/sm4267/workspace/web/checkout-sdk-native/showcase-ios` and inside it `git pull <SDK repo path> showcase-split` so the new repo's `main` holds the history (`git branch -M main` if needed). Verify: `git log --oneline | wc -l` in the new repo is ≥ 20 and `git ls-files | grep -cE "xcodeproj|xcworkspace|Derived"` is 0. Delete the split branch in the SDK repo (`git branch -D showcase-split`; it is a local temporary branch created in this step).
- [ ] **Step 2:** `.gitignore` (new repo): `*.xcodeproj`, `*.xcworkspace`, `Derived/`, `.build/`, `xcuserdata/`, `.DS_Store`, `credentials.env`. `Project.swift`: package path `../ios`; update the header comment (sibling SDK repo, local path, switch to a git URL + version once the SDK is tagged). Verify with `git check-ignore -v credentials.env`.
- [ ] **Step 3:** `AGENTS.md` (new repo, English): what the app is (internal Sunbay Coffee demo, internal TestFlight audience only), SDK dependency by local path (`../ios` must be cloned next to it), real dev orders only (no mocks), credentials never committed/logged and must be test-environment keys, how to generate/build/test, git rules (no `git add .`, feature branches, never commit `credentials.env`). `README.md`: replace "All payments are simulated" with: payments are real orders on the dev test merchant (no real money); add a "Repository layout" note about `../ios`. Credential setup is added in Task 2.
- [ ] **Step 4:** Remove any stale generated output copied from the old location, then `tuist generate --no-open` in the new repo, build `xcodebuild -workspace Showcase.xcworkspace -scheme Showcase -destination 'id=D8302CDE-6AD6-4593-9A11-6F7BC3C9DB57' build` (BUILD SUCCEEDED) and `xcodebuild test` with the same destination (all pass; the mock-based tests still exist at this point).
- [ ] **Step 5: Commit** (new repo): `.gitignore`, `AGENTS.md`, `README.md`, `Project.swift`: `chore: stand up Showcase as its own repository next to the SDK`.

---

### Task 2: Showcase real orders with an in-app SessionCreator

**Files (new repo):**
- Create: `Shared/Checkout/SessionCreator.swift`, `Shared/Checkout/ShowcaseCredentials.swift`, `credentials.env.example`, `Tests/SessionCreatorTests.swift`, `Tests/ShowcaseCredentialsTests.swift`
- Modify: `Project.swift` (Tuist `Environment` values → Info.plist keys), `Shared/Checkout/CheckoutPresenter.swift`, `Shared/Screens/CartView.swift` (pass cart lines; error toast for not-configured / create failure), `Shared/Strings/Strings.swift` + `Resources/*.lproj` if the toast copy lives there, `README.md`
- Delete: `Shared/Mock/ShowcaseServices.swift`, `Tests/ShowcaseServicesTests.swift`
- Local only, git-ignored: `credentials.env`

**Interfaces:**
- Produces:
  - `struct ShowcaseCredentials: Equatable { let apiKey: String; let appId: String; let merchantAccountId: String; let customerId: String; let openAPIURL: URL; static func load(from info: [String: Any]) -> ShowcaseCredentials? }` — nil when `apiKey`, `appId` or `merchantAccountId` is empty; `customerId` defaults to `sunbay-showcase-customer`, `openAPIURL` to `https://open.sunbay-dev.com`. Conforms to `CustomStringConvertible` with a description that omits the key.
  - Info.plist keys: `ShowcaseOpenAPIKey`, `ShowcaseOpenAppId`, `ShowcaseOpenMerchantId`, `ShowcaseOpenCustomerId`, `ShowcaseOpenAPIURL`, filled from Tuist `Environment.sunbayShowcaseApiKey`, `.sunbayShowcaseAppId`, `.sunbayShowcaseMerchantAccountId`, `.sunbayShowcaseCustomerId`, `.sunbayShowcaseOpenApiUrl` (i.e. `TUIST_SUNBAY_SHOWCASE_API_KEY`, `..._APP_ID`, `..._MERCHANT_ACCOUNT_ID`, `..._CUSTOMER_ID`, `..._OPEN_API_URL`), defaults empty except the two defaults above.
  - `struct CreatedSession: Equatable { let sessionId: String; let checkoutClientSecret: String; let customerAccessSecret: String? }`
  - `struct SessionLine { let name: String; let unitAmountMinor: Int64; let quantity: Int }`
  - `enum SessionCreator { static func makeRequest(lines: [SessionLine], credentials: ShowcaseCredentials, now: Date) throws -> URLRequest; static func create(lines: [SessionLine], credentials: ShowcaseCredentials, session: URLSession = .shared) async throws -> CreatedSession }` — headers and body per the Global Constraints and spec §5.2; `X-Client-Request-Id` equals `transactionRequestId`; `X-Timestamp` is `now` in ms; `description` "Sunbay Coffee order"; `merchantReturnUrl`/`notifyUrl` "". Errors: `SessionCreatorError.notConfigured`, `.upstream(code: String?, httpStatus: Int)`, `.invalidResponse(httpStatus: Int)`; their descriptions never contain the key, the body or secrets.
  - `CheckoutPresenter.pay(lines: [SessionLine], theme:language:systemIsDark:) async -> PaymentAttempt` where `enum PaymentAttempt { case presented(PaymentResult); case notConfigured; case sessionFailed; case busy }`.

- [ ] **Step 1: Write failing tests.** `SessionCreatorTests` (pure, no network): for lines latte 550×2 + croissant 350×1 and a fixed `now`, the request is `POST https://open.sunbay-dev.com/v1/checkout/create-session`; headers `Authorization == "Bearer k"`, `Content-Type == "application/json"`, `X-Client-Request-Id` equals body `transactionRequestId` and starts with `SBC`, `X-Timestamp == String(ms)`; body `amount.orderAmount == 1450`, `amount.taxAmount == 0`, `amount.priceCurrency == "USD"`, `sessionType == "sdk"`, `customerId == "sunbay-showcase-customer"`, `supportStoreCard == true`, `collectBillingAddress == false`, `collectShippingAddress == false`, `productList == [{name:"Latte",amount:550,num:2},{name:"Croissant",amount:350,num:1}]`, `appId`, `merchantId` from credentials. Response parsing (via a stub `URLProtocol`): code "0" with data → `CreatedSession`; code "S01" → `.upstream(code:"S01", httpStatus:200)`; HTML body → `.invalidResponse`; `String(describing:)` of every error and of `ShowcaseCredentials` does not contain "k". `ShowcaseCredentialsTests`: empty key → nil; full dict → values; missing URL/customer → defaults. Run `xcodebuild test ... -only-testing:ShowcaseTests/SessionCreatorTests -only-testing:ShowcaseTests/ShowcaseCredentialsTests`; expected FAIL (types missing).
- [ ] **Step 2: Implement** the interface block. Product names come from the English catalog strings (`Strings` lookup with `en`), so the backend always gets English names. Top-of-file comment in `SessionCreator.swift`: "INTERNAL SHOWCASE ONLY. Creating sessions in an app ships the merchant API key inside the binary. This is accepted only for the internal test merchant on dev; production integrations must create sessions on their own server."
- [ ] **Step 3: Wire the presenter.** `pay` loads `ShowcaseCredentials.load(from: Bundle.main.infoDictionary ?? [:])` (nil → `.notConfigured`, no request), creates the session (error → `.sessionFailed`), then `SunbayCheckout(configuration: makeConfiguration(...))` and `PaymentSheet(checkout:sessionId:customerAccessSecret:checkoutClientSecret:)`. `CartView` maps `.notConfigured` to a toast "Showcase is not configured. Set the credentials and regenerate." (en + zh-Hans), `.sessionFailed` to the existing payment-failed toast, `.busy` to no-op. Delete `ShowcaseServices.swift` and its test file; update `CheckoutPresenterTests` if it referenced them.
- [ ] **Step 4: Credentials.** `credentials.env.example` lists the five `TUIST_SUNBAY_SHOWCASE_*` variables (empty values, with a comment that keys must be dev/test only and the file must never be committed) plus the existing merchant-id/bundle-id/team ones. Create the git-ignored `credentials.env` by mapping `API_KEY`, `APP_ID`, `MERCHANT_ID` from `/Users/sm4267/workspace/web/checkout-sdk-web/js/example/.env.local` to `TUIST_SUNBAY_SHOWCASE_API_KEY`, `..._APP_ID`, `..._MERCHANT_ACCOUNT_ID` with a small script that never prints values (`export` lines). Verify `git status --short` does not list it. README "Configure credentials": `cp credentials.env.example credentials.env`, fill in, `set -a; source credentials.env; set +a; tuist generate`.
- [ ] **Step 5: Live check (skips without credentials).** `Tests/SessionCreatorLiveTests.swift`: reads credentials from the test bundle host's Info.plist; `XCTSkip` when not configured; creates a session for one latte and asserts `sessionId` non-empty, `checkoutClientSecret` starts with `ccs_`, `customerAccessSecret` starts with `cas_`. Run with credentials sourced: `set -a; source credentials.env; set +a; tuist generate --no-open` then the full `xcodebuild test`. Expected: all pass, live test passes. Then regenerate without sourcing and confirm the app still builds and the live test skips.
- [ ] **Step 6: Commit** (new repo, exact files incl. deletions via `git rm`): `feat: create real dev sessions in the app and remove the mock services`.

---

### Task 3: Remove Showcase from the SDK repo

**Files (SDK repo):**
- Delete: `Showcase/` (`git rm -r Showcase`; afterwards also remove the untracked generated leftovers in that folder)
- Modify: `.gitignore` (drop the `Showcase/...` lines), `AGENTS.md` (§3 tree: no Showcase; Example is real-only, dev environment; mention the sibling `showcase-ios` repo in one line), `docs/real-api-integration-checklist.md` (lines about Showcase mock services → "Showcase moved to `showcase-ios` and creates real dev sessions"), any `README.md`/`docs/*.md` (not `docs/superpowers/`) line that refers to `Showcase/`

**Interfaces:** none.

- [ ] **Step 1:** Only after Task 2 is committed in the new repo: `git rm -r -q Showcase`, then `rm -rf Showcase` for untracked leftovers. Edit the listed files. Verify `grep -rn "Showcase" AGENTS.md README.md docs/*.md .gitignore` shows only the intended new references.
- [ ] **Step 2:** `swift build` and `swift test` (0 failures).
- [ ] **Step 3: Commit** (exact paths): `chore: remove Showcase (moved to the showcase-ios repository)`.

---

### Task 4: Example app real-only, fixed to dev

**Files (SDK repo):**
- Modify: `Example/SunbayCheckoutDemo/Sources/DemoSettings.swift`, `Example/SunbayCheckoutDemo/Sources/DemoRootView.swift`, `Sources/SunbayCheckoutTestSupport/DevSessionClient.swift`, `Example/README.md`, `Sources/SunbayCheckoutTestSupport/*.swift` header comments that say the Example uses the scriptable doubles
- Test: `Tests/SunbayCheckoutTests/Support/DevSessionClientTests.swift` (new)

**Interfaces:**
- Produces:
  - `DevSessionClient.createSession(amountMajorUnits: Double = 0.01, collectBillingAddress: Bool = false, collectShippingAddress: Bool = false) async throws -> DevSession` (adds `collectShippingAddress` to the JSON body; existing callers keep compiling).
  - `DemoSettings` keeps: `locale`, `amountMinorUnits` (shown as USD, sent as major units = minor / 100), `cardOnFileEnabled`, `preTickSaveCard`, `appearancePreset`, `colorScheme`, `billingAddressMode`, `shippingAddressMode`, `devServerURL`, and the PaymentSheet title if it exists. Removed: `DemoEnvironment`, `environment`, `DemoMode`, `mode`, `DemoMethod`, `methods`, `cofEnabled`, `DemoScenario`, `scenario`, `currencyCode`.
  - Address mode `.none` → `collectX = false`; `.simple`/`.full` → `collectX = true` and the matching `Appearance` mode as today.

- [ ] **Step 1: Write failing test** `DevSessionClientTests` (stub `URLProtocol` session injected through a new public initializer `init(serverURL: URL, session: URLSession)` — public because the test target imports `SunbayCheckoutTestSupport` without `@testable`; keep `init(serverURL:)` using `.shared`): body contains `amount 1.05`, `collectBillingAddress true`, `collectShippingAddress true`; a 503 throws a `DevSessionError` whose description contains "503". Run `swift test --filter DevSessionClientTests`; expected FAIL.
- [ ] **Step 2: Implement** `DevSessionClient` changes; run the test (PASS).
- [ ] **Step 3: Example.** Remove the mode, environment, methods, scenario and mock-COF sections and their helpers (`makePaymentService`, `makeCofService`, scripted address service); `makeCheckout()` returns `SunbayCheckout(configuration: CheckoutConfiguration(environment: .dev, ...))` always; the DEV ONLY banner is always shown; the amount section is always visible (USD, fixed currency caption); the address footer says full mode has no country data until the backend address integration (phase 3). Pay always creates a session via `DevSessionClient` (invalid URL → "Invalid server URL"; failure → error text) with `collectBillingAddress`/`collectShippingAddress` from the address modes. The standalone ApplePayButton section: a "Create session" button that creates a session and then shows `ApplePayButton` built with that session's `sessionId` and `checkoutClientSecret`; it shows the session-creation error otherwise. Remove `#if DEBUG` gating that only existed to hide the real mode (the whole Example is a dev app now) but keep the Example out of release builds of the SDK (it already is). Keep `NSAllowsLocalNetworking`.
- [ ] **Step 4:** Update `Example/README.md` (real-only flow, start the dev server first, dev environment fixed, settings list) and the TestSupport header comments. `tuist generate --no-open` in `Example/SunbayCheckoutDemo`, then `xcodebuild -workspace Example/SunbayCheckoutDemo/SunbayCheckoutDemo.xcworkspace -scheme SunbayCheckoutDemo -destination 'generic/platform=iOS Simulator' build` (BUILD SUCCEEDED); `swift test` (0 failures); `scripts/run-dev-e2e.sh` (passes; card-dependent tests skip).
- [ ] **Step 5: Commit** (exact files): `refactor(example): real dev orders only, fixed dev environment`.

---

## Self-review notes

- Spec coverage: §5.1 (Task 1), §5.2 (Task 2), §5.3 (Task 4), §5.4 (Task 3), §5.5 branches/commits (Global Constraints), §5.6 verification (each task's final steps). Open items §6 stay with the user.
- Ordering: Task 3 deletes Showcase only after Task 2 is committed in the new repo; Task 4 is independent of Showcase.
- Names used across tasks: `SessionCreator.makeRequest/create`, `SessionLine`, `CreatedSession`, `ShowcaseCredentials.load(from:)`, `PaymentAttempt`, `DevSessionClient.createSession(amountMajorUnits:collectBillingAddress:collectShippingAddress:)`, `init(serverURL:session:)`.
