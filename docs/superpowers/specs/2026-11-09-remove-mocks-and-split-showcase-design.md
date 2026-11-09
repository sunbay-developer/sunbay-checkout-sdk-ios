# Remove app mocks and split Showcase into its own repo — design

Status: draft for review. Date: 2026-11-09.

## 1. Intent

The SDK now talks to the real backend (phases 1-2). The demo apps still default to scripted mock
services, which hides real integration problems and keeps two code paths alive. From now on every
demo payment is a real order on the dev environment: create a session, then present the SDK.

Showcase (the internal "Sunbay Coffee" demo app shipped on TestFlight to leaders and customers) is
internal only and must not ship with the SDK repo, so it moves to its own repository and creates its
sessions directly from the app with a test-environment merchant.

## 2. Goals, non-goals, anti-goals

Goals
- Example app: mock mode removed; every payment creates a session through the local dev server
  (`Example/DevServer`) and pays against `dev`. No environment picker.
- Showcase: own git repo next to the SDK (`../showcase-ios`), history preserved, real orders on `dev`
  created in the app with a test merchant, no mock services left.
- SDK repo: `Showcase/` removed; docs and ignores updated.

Non-goals
- Unit and e2e test doubles stay (`Tests/SunbayCheckoutTests/Support/Mock*`, `SunbayCheckoutTestSupport`
  `Scriptable*` / `DemoSessionFactory`): they are what keeps `swift test` offline and deterministic. They are
  test infrastructure, not app mocks.
- The SDK public default `CheckoutConfiguration.Environment` stays `.production` (an integrator who passes
  nothing must never hit dev). "Dev only" applies to the two apps.
- No new SDK features; no address (phase 3) or card rules (phase 4) work.

Anti-goals
- Merchant API credentials committed to either repository, or printed in logs.
- Showcase credentials that also work on production.
- Breaking `swift test`, the real-API tests, or the Example localization gate.

## 3. Constraints

- English only in code and docs of both repos (`AGENTS.md` §2).
- Showcase depends on the SDK by local path; it builds only when the SDK repo sits next to it.
- The SDK has no release tag yet; switching Showcase to a git URL + version is a later change.
- Showcase audience is internal only from now on (user, 2026-11-09). Shipping the test-merchant key inside the
  app is an accepted, user-decided risk: anyone holding the build can extract it, so the key must be a
  dev/test-environment key and the TestFlight audience must stay internal. If the audience ever widens, replace
  in-app session creation with a hosted session endpoint.

## 4. Approaches (repo split)

- **A. Sibling repo, local path dependency (chosen by the user).** `/Users/sm4267/workspace/web/checkout-sdk-native/showcase-ios`,
  `.package(path: "../ios")`. SDK changes are visible immediately; cloners must also clone the SDK next to it.
- B. Standalone repo, git URL dependency on `main`. Builds alone, but every SDK change must be pushed first;
  too slow during internal iteration. Rejected for now; becomes the setup once the SDK is tagged.

## 5. Design

### 5.1 Showcase repo

- Create with `git subtree split --prefix=Showcase` from the SDK repo (keeps its ~24 commits), then
  initialize `/Users/sm4267/workspace/web/checkout-sdk-native/showcase-ios` from that branch. Local only; the
  user creates the remote and pushes. The temporary split branch is deleted from the SDK repo afterwards.
- `Project.swift`: `.package(path: "../ios")` instead of `..`. Own `.gitignore` (Tuist outputs, `Derived/`,
  `.build/`, `xcuserdata/`, credentials file). Own short `README.md` and `AGENTS.md` (English only, no secrets,
  real orders only, how to configure credentials).
- Environment fixed to `.dev` (already the case in `CheckoutPresenter`).

### 5.2 Showcase session creation in the app

- New `Shared/Checkout/SessionCreator.swift`: Swift port of `Example/DevServer/session.mjs` (`createSession`):
  `POST {openApiURL}/v1/checkout/create-session`, headers `Content-Type: application/json`,
  `Authorization: Bearer <apiKey>`, `X-Client-Request-Id: <transactionRequestId>`, `X-Timestamp: <ms>`; body with
  `appId`, `merchantId`, `transactionRequestId`/`referenceOrderId` (`SBC<ms>`), `amount {orderAmount = cart total,
  taxAmount = 0, priceCurrency = "USD"}` (my call: the cart shows USD prices without tax, so the paid amount must equal
  the displayed total; the dev server's 8 % tax is not copied), `description`, `productList` (the cart lines, minor units), `collectBillingAddress: false`,
  `collectShippingAddress: false`, `sessionType: "sdk"`, `customerId`, `supportStoreCard: true`,
  `merchantReturnUrl`/`notifyUrl` empty. Success is `code == "0"` with `data.sessionId`; returns
  `sessionId`, `checkoutClientSecret`, `customerAccessSecret`.
- Credentials: Tuist `Environment` at generate time (`TUIST_SUNBAY_SHOWCASE_API_KEY`, `..._APP_ID`,
  `..._MERCHANT_ACCOUNT_ID` (open-platform merchant id, distinct from the Apple Pay merchant id), `..._CUSTOMER_ID`
  (default `sunbay-showcase-customer`), `..._OPEN_API_URL` (default `https://open.sunbay-dev.com`)) written into Info.plist keys; read at runtime. A git-ignored `credentials.env` (template
  `credentials.env.example` committed) plus a one-line `source credentials.env && tuist generate` instruction.
  Initial values are copied from the JS example `.env.local` (same sandbox merchant) by the builder; never printed.
  TestFlight/Archive builds are produced on the release engineer's Mac with the same `source credentials.env &&
  tuist generate` step (no CI today; my call).
- Missing credentials: the Pay button shows a clear error ("Showcase is not configured: set the credentials and
  regenerate"); nothing crashes.
- `SessionCreator` errors carry only the upstream `code`/`msg` and HTTP status, never the key or the body.
- Prominent comment at the top of `SessionCreator.swift` and in the README: internal test-merchant app only;
  production integrations must create sessions on their own server; the key must be a test-environment key.
- `CheckoutPresenter.pay`: create the session, then `SunbayCheckout(configuration:)` (real services) and
  `PaymentSheet(checkout:sessionId:customerAccessSecret:checkoutClientSecret:)`. While creating, the existing
  presenting guard prevents double taps; an error goes to the existing toast.
- Delete `Shared/Mock/ShowcaseServices.swift` and `Tests/ShowcaseServicesTests.swift`. Add unit tests for the
  pure request builder (body fields and headers, minor units, ids) and for credential loading (missing key →
  not configured). Update the README: payments are real orders on the dev test merchant (still no real money).

### 5.3 Example app (SDK repo)

- Remove `DemoMode` and the mock path; the app always uses `DevSessionClient` and `SunbayCheckout(configuration:)`.
- Remove `DemoEnvironment` and the picker; configuration is always `.dev`. The banner (DEV ONLY, dev server URL)
  stays. Keep the editable dev-server URL (real devices need the Mac's LAN address).
- Remove knobs that only scripted the mock: payment-method set, scenario, mock COF saved cards, currency. The
  backend decides methods and results.
- Keep: locale, appearance preset, color scheme, card-on-file switches, amount (sent to the dev server in major
  units via `DevSessionClient.createSession(amountMajorUnits:)`), billing/shipping address *collection* switches
  passed to the dev server (`collectBillingAddress`/`collectShippingAddress`), PaymentSheet title.
- Address "full mode" no longer has fixture data: it uses the SDK default (empty, fail-soft) metadata service
  until phase 3; the footer says so.
- Standalone `ApplePayButton` (L3): needs a session at construction, so its section gets a "Create session"
  action first, then shows the button for that session.
- `Project.swift`: keep `SunbayCheckoutTestSupport` only for `DevSessionClient`.
- `Example/README.md`: real-only flow, how to start the dev server, no mention of mock mode.

### 5.4 SDK repo cleanup

- `git rm -r Showcase`; remove its `.gitignore` lines; update `AGENTS.md` §3 tree (no Showcase; Example is
  real-only), `docs/real-api-integration-checklist.md` mentions of Showcase mocks, `README.md` if it mentions
  Showcase. Historical specs and plans under `docs/superpowers/` stay as written.
- `SunbayCheckoutTestSupport` comment: the Example uses only `DevSessionClient`; the scriptable doubles serve tests.

### 5.5 Branches and commits (my call)

- SDK repo: work on `chore/remove-mocks-split-showcase` (never on `main`), per-task commits with exact files, no push.
- `showcase-ios`: created from the subtree split (history preserved), changes committed locally on its `main`;
  the user adds the remote and pushes. Only tracked files move (generated `*.xcodeproj`, `*.xcworkspace` and
  `Derived/` are untracked in the SDK repo, verified).

### 5.6 Verification

- SDK repo: `swift test` green; Example `tuist generate` + simulator build green; `scripts/run-dev-e2e.sh` green
  (card tests run by the controller with the sandbox card via env).
- Showcase repo: `tuist generate` + simulator build + `xcodebuild test` green; one manual-equivalent check of
  `SessionCreator` against dev (create a session, assert `ccs_`/`cas_`), driven from a test that skips without
  credentials.

## 6. Open items

1. The user confirms the Showcase test merchant (the JS example sandbox merchant is the starting point) and that
   its key is test-environment only.
2. Remote for `showcase-ios` (created and pushed by the user).
3. Verify on a real device outside the office network that `open.sunbay-dev.com` and the dev checkout origin are
   reachable, and that Apple Pay with `merchant.native.com.sunbay.dev` works against dev (already an open
   checklist item for Apple Pay). Until then, card payments are the verified demo path. Demos now show live dev
   results; scripted failure scenarios are gone by design.

## 7. Left to the builder

Exact file names inside Showcase beyond `SessionCreator.swift`, Info.plist key names, UI copy for the
not-configured error, how the Example lays out the remaining knobs.
