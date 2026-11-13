# Card rules sync Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** The SDK checks HPP's live card-brand rules on its own, overwrites the local cached copy when the live one changed, and ships the HPP document as its bundled fallback. BIN recognition stays dormant.

**Architecture:** A new `HTTPCardRulesService` (raw conditional GET through `SunbayAPIClient`) is built in `SunbayCheckout`, threaded through `UIWiring` to `NewCardEntryView` in both the PaymentSheet and the Elements `CardElement`; building a card form triggers `CardRulesRefresher` (time-gated, at most once per hour per process). A valid new document replaces the cache and applies the next time a card form is shown. The bundled copy is produced by a script and never edited by hand.

**Tech Stack:** Swift, Foundation `URLSession`, XCTest, bash.

**Spec:** `docs/superpowers/specs/2026-11-13-card-rules-sync-design.md` (contract: `docs/card-rules-contract.md`).

## Global Constraints

- English only in code, comments, tests, docs (AGENTS.md rule 2). No commits unless the user asks; never `git add .` (the commit steps below are for when the owner asks).
- No public API change: `CardRulesService` / `CardBinService` stay `internal`. `Core` stays UI-agnostic (Foundation only).
- BIN recognition is **not** wired: `CardBinService` / `CardSchemeResolver` / `EmptyCardBinService` are untouched; no `HTTPCardBinService`; no BIN leaves the device.
- Rules request: `GET <origin>/api/card/rules`, timeout 3 s, no retry, no URLCache (the client session is ephemeral), `If-None-Match` = stored ETag **verbatim including quotes**, response is the raw document (no envelope). Any non-200/304, transport failure or invalid document means "keep current rules".
- Refresh cadence: at most one check per hour per process, evaluated when a card form is built; an applied update takes effect the next time a card form is shown, never mid-typing.
- Document sanity bounds stay as in `CardRuleSet.parse` (do not loosen). Scheme key `diners` is read as `dinersclub` (temporary shim; remove once HPP's rename is deployed everywhere).
- Nothing about the rules request is logged except through the existing DEBUG-only `NetworkDebugLogger` (the document is public data).

## Review Focus

- A `200` with an invalid / oversized / unknown-`schemaVersion` document must not replace a good cache (task 3 test).
- A cached document that no longer parses must fall back to bundled, and the stale ETag must not be sent (task 3 test; `CardRulesStore.etag()` already requires a valid stored doc).
- ETag containing quotes must be echoed byte-for-byte in `If-None-Match` (task 2 test).
- A failed or `304` check still counts toward the hourly gate, so a flapping server is not hammered (task 3 test).
- Two card forms built back to back (Elements) trigger one request, not two (task 3/4 test).
- The old cached doc with key `diners` still yields Diners rules and icon (task 1 test).

---

## File Structure

- Modify `Sources/SunbayCheckout/Core/CardBrand/CardRuleSet.swift` — `diners` alias.
- Modify `Sources/SunbayCheckout/Core/Network/SunbayEndpoints.swift`, `SunbayAPIClient.swift` — `.cardRules` route, raw GET.
- Create `Sources/SunbayCheckout/Core/CardBrand/HTTPCardRulesService.swift` — the adapter.
- Modify `Sources/SunbayCheckout/Core/CardBrand/CardRulesProvider.swift` — time-gated refresher.
- Modify `Public/SunbayCheckout.swift` (`UIWiring`), `UI/PaymentSheet/PaymentSheet.swift`, `UI/Elements/{CheckoutElements,CardElement}.swift`, `UI/Content/Components/NewCardEntryView.swift` — wiring and trigger.
- Replace `Sources/SunbayCheckout/Resources/CardRules/card-brand-rules.json`; create `scripts/update-card-rules.sh`.
- Tests under `Tests/SunbayCheckoutTests/Core/` (new files named below).
- Docs: `docs/card-rules-contract.md` §4.1, `docs/product-spec.md` §7, `docs/real-api-integration-checklist.md` §1, `docs/security-and-pci.md`.

---

### Task 1: Rule set tests and the `diners` shim

**Files:**
- Modify: `Sources/SunbayCheckout/Core/CardBrand/CardRuleSet.swift` (`RawBrand.converted()`)
- Create: `Tests/SunbayCheckoutTests/Core/CardRuleSetTests.swift`

**Interfaces:**
- Produces: `CardRuleSet.parse(_:)` maps a brand `scheme` of `diners` (case-insensitive) to `dinersclub`. A test helper `CardRuleSetTests.document(brands:)` is **not** shared; tests build their own JSON strings.

- [ ] **Step 1: Write failing tests** in `CardRuleSetTests` (no tests exist for `CardRuleSet` today):
  - `test_parse_acceptsMinimalValidDocument`
  - `test_parse_rejectsUnknownSchemaVersion` (`schemaVersion: 2` → nil)
  - `test_parse_rejectsOversizedDocument` (> `maxDocumentBytes` → nil)
  - `test_parse_rejectsBadGroupsAndCvvSizes` (`groups: [20]`, `cvv.sizes: [5]` → nil)
  - `test_parse_rejectsMoreThan64Brands`
  - `test_parse_mapsDinersKeyToDinersclub`: document with brand `"diners"` → `brands.first.scheme == "dinersclub"`; and `rules(forScheme: "dinersclub").displayName == "Diners Club"`.
  - `test_detectScheme_dinersPrefixResolvesToDinersclub`: typed `36` → `"dinersclub"` from a `diners`-keyed document.
- [ ] **Step 2: Run** `swift test --filter CardRuleSetTests`. Expected: only the two `diners` tests fail.
- [ ] **Step 3: Implement** in `RawBrand.converted()`: after lower-casing, `scheme == "diners" ? "dinersclub" : scheme`. Add a doc comment that it is a temporary shim for HPP documents published before the rename.
- [ ] **Step 4: Run** the same command. Expected: all pass.
- [ ] **Step 5: Commit** `git add Sources/SunbayCheckout/Core/CardBrand/CardRuleSet.swift Tests/SunbayCheckoutTests/Core/CardRuleSetTests.swift` — `test(card-rules): cover rule set parsing and alias diners to dinersclub`.

### Task 2: Raw GET and `HTTPCardRulesService`

**Files:**
- Modify: `Sources/SunbayCheckout/Core/Network/SunbayEndpoints.swift`, `Sources/SunbayCheckout/Core/Network/SunbayAPIClient.swift`
- Create: `Sources/SunbayCheckout/Core/CardBrand/HTTPCardRulesService.swift`
- Test: `Tests/SunbayCheckoutTests/Core/HTTPCardRulesServiceTests.swift`, extend `SunbayEndpointsTests.swift`

**Interfaces:**
- Produces: `SunbayEndpoints.Route.cardRules` → `<origin>/api/card/rules`.
- Produces: `SunbayAPIClient.getRaw(_ route: SunbayEndpoints.Route, headers: [String: String] = [:], timeout: TimeInterval = 3) async throws -> (Data, HTTPURLResponse)` — no envelope decoding, no retry, returns any HTTP status; transport failure throws the existing `NETWORK_UNAVAILABLE` `CheckoutError`. Sends the same `Accept` (`application/json`), `X-Sunbay-SDK` and `Accept-Language` headers as `get`, plus `headers`.
- Produces: `struct HTTPCardRulesService: CardRulesService { init(client: SunbayAPIClient) }`.

- [ ] **Step 1: Write failing tests** (use `StubURLProtocol.session()` like `HTTPAddressMetadataServiceTests`):
  - `testURLIsCardRulesPath` (endpoints test, dev/test/production origins).
  - `testFetchWithoutETagSendsNoIfNoneMatch`
  - `testFetchSendsStoredETagVerbatim`: stored `"abc123"` **with quotes** → request header `If-None-Match` equals `"abc123"` exactly.
  - `test200ReturnsBodyBytesAndETagHeader` → `.updated(bytes, etag: "\"abc123\"")`, bytes identical to the body.
  - `test200WithoutETagHeaderReturnsNilETag`
  - `test304ReturnsNotModified`
  - `testOtherStatusesThrow` (404, 429, 500, with an envelope-shaped error body).
  - `testTransportFailureThrows`
  - `testRequestTimeoutIsThreeSecondsAndNotRetried`: handler counts calls on a failing transport → exactly 1 call; `request.timeoutInterval == 3`.
- [ ] **Step 2: Run** `swift test --filter "HTTPCardRulesServiceTests|SunbayEndpointsTests"`. Expected: compile failure / FAIL.
- [ ] **Step 3: Implement** the route, `getRaw` (reuse the private `send`), and the adapter: `304` → `.notModified`; `200` → `.updated(data, etag: response.value(forHTTPHeaderField: "ETag"))`; anything else throws a `CheckoutError` with code `HTTP_<status>` and category `.network` (never include body/URL).
- [ ] **Step 4: Run** the same command. Expected: PASS. Also run `swift build`.
- [ ] **Step 5: Commit** the five files — `feat(card-rules): HTTP adapter for GET /api/card/rules`.

### Task 3: Time-gated refresher

**Files:**
- Modify: `Sources/SunbayCheckout/Core/CardBrand/CardRulesProvider.swift`
- Test: `Tests/SunbayCheckoutTests/Core/CardRulesRefresherTests.swift`

**Interfaces:**
- Produces: `final class CardRulesRefreshGate: @unchecked Sendable { init(minInterval: TimeInterval = 3600); func claim(now: Date = Date()) -> Bool; static let shared }` — returns true and records `now` when no claim happened within `minInterval`, thread-safe (NSLock).
- Produces: `CardRulesRefresher.refreshInBackground(service: any CardRulesService, store: CardRulesStore = CardRulesStore(), gate: CardRulesRefreshGate = .shared)` (replaces the process-once `RefreshState`). `refresh(service:store:)` keeps its signature.

- [ ] **Step 1: Write failing tests**:
  - `test_gate_firstClaimTrue_secondWithinIntervalFalse_afterIntervalTrue` (inject dates).
  - `test_refresh_updated_validDocument_savesDocumentAndETag` (temp directory `CardRulesStore(directory:)`, then `store.load()` equals the parsed doc and `store.etag()` equals the header).
  - `test_refresh_updated_invalidDocument_keepsPreviousCache` (seed a good doc, service returns garbage / `schemaVersion: 2` / oversized → store unchanged, ETag unchanged).
  - `test_refresh_notModified_keepsCache`
  - `test_refresh_serviceThrows_keepsCache`
  - `test_refresh_sendsStoredETag`: scriptable service records the `ifNoneMatch` it receives; second refresh after a save sends the saved ETag.
  - `test_store_corruptCachedDocument_loadsNilAndNoETag` (write garbage file → `load() == nil`, `etag() == nil`) and `test_activeRuleSet_fallsBackToBundledWhenCacheCorrupt`.
  - `test_refreshInBackground_twoCallsSameGate_oneFetch` (service counts calls; await completion via an expectation fulfilled in the service).
  - `test_refreshInBackground_failedCheckStillConsumesGate`.
- [ ] **Step 2: Run** `swift test --filter CardRulesRefresherTests`. Expected: FAIL (compile).
- [ ] **Step 3: Implement** the gate and swap `RefreshState` for it; keep `Task.detached(priority: .utility)`.
- [ ] **Step 4: Run** the same command. Expected: PASS.
- [ ] **Step 5: Commit** — `feat(card-rules): hourly gated background refresh`.

### Task 4: Wiring and trigger in both shells

**Files:**
- Modify: `Sources/SunbayCheckout/Public/SunbayCheckout.swift` (add `cardRulesService` to the internal designated init, `makeUIWiring`, `UIWiring`), `UI/PaymentSheet/PaymentSheet.swift`, `UI/Elements/CheckoutElements.swift`, `UI/Elements/CardElement.swift`, `UI/Content/Components/NewCardEntryView.swift`
- Test: `Tests/SunbayCheckoutTests/Public/SunbayCheckoutDefaultWiringTests.swift` (extend), `Tests/SunbayCheckoutTests/UI/NewCardEntryViewTests.swift` (extend)

**Interfaces:**
- Consumes: `HTTPCardRulesService(client:)` (task 2), `CardRulesRefresher.refreshInBackground(service:store:gate:)` (task 3).
- Produces: `SunbayCheckout.cardRulesService: any CardRulesService` (internal). The default (`init(configuration:)`) wiring uses `HTTPCardRulesService(client: client)`; the internal designated init takes `cardRulesService: (any CardRulesService)? = nil` defaulting to `EmptyCardRulesService()`; the public service-injection init keeps its signature (empty default). `UIWiring.cardRulesService`.
- Produces: `NewCardEntryView.init` gains no new parameter (it already receives `cardRulesService`) and calls `CardRulesRefresher.refreshInBackground(service: cardRulesService, store: cardRulesStore, gate: cardRulesGate)` once at the end of init, where `cardRulesStore: CardRulesStore = CardRulesStore()` and `cardRulesGate: CardRulesRefreshGate = .shared` are new **defaulted** init parameters (tests inject temp store / own gate).
- `PaymentSheet` internal init, its runner, and `CheckoutContentViewController` call site pass `cardRulesService` (the content VC already has the parameter); `CheckoutElements.create(...)` (public wrapper reads `wiring.cardRulesService`; internal seam gets `cardRulesService: any CardRulesService = EmptyCardRulesService()`), the group stores it, `CardElement` passes it instead of `EmptyCardRulesService()`.

- [ ] **Step 1: Write failing tests**:
  - Default wiring: `SunbayCheckout(configuration:)` exposes a non-empty rules service — `XCTAssertTrue(checkout.cardRulesService is HTTPCardRulesService)`; the service-injection init exposes `EmptyCardRulesService`.
  - `NewCardEntryViewTests.test_init_triggersRulesRefreshOnce`: construct two `NewCardEntryView`s with a counting `CardRulesService`, a temp `CardRulesStore` and one shared `CardRulesRefreshGate` → service called once.
  - `NewCardEntryViewTests.test_init_withEmptyService_doesNotWriteStore` (store stays empty).
  - Elements: extend `CardElementTests` (or `ElementsScenarioTests`) — a group created with a counting rules service and a `CardElement` mounted triggers exactly one fetch; a group with only `ExpressCheckoutElement` triggers none.
- [ ] **Step 2: Run** `swift test --filter "SunbayCheckoutDefaultWiringTests|NewCardEntryViewTests|CardElementTests"` (host `swift test` skips UIKit targets; run the iOS gate from the spec's verification section for the UI tests). Expected: FAIL.
- [ ] **Step 3: Implement** the threading exactly as in Interfaces. Do not touch `cardBinService` anywhere (stays `EmptyCardBinService`).
- [ ] **Step 4: Run** `swift build`, `swift test`, then the iOS simulator gate `xcodebuild -scheme SunbayCheckout-Package -destination 'platform=iOS Simulator,id=1B87355C-2AA1-4EDF-A89A-24DA4EE53A06' test > /tmp/ios-test.log 2>&1; grep -E "error: -\[|\*\* TEST" /tmp/ios-test.log | grep -v kTCC`. Expected: only the known `BottomSheetLayoutTests.test_install_unmeasured_usesInitialHeightSoEntranceHasAFrame` failure.
- [ ] **Step 5: Commit** — `feat(card-rules): wire the rules service into PaymentSheet and Elements`.

### Task 5: Bundled document, update script, contract vectors

**Files:**
- Create: `scripts/update-card-rules.sh`
- Replace: `Sources/SunbayCheckout/Resources/CardRules/card-brand-rules.json`
- Test: `Tests/SunbayCheckoutTests/Core/CardRulesContractVectorsTests.swift`

**Interfaces:**
- Produces: `scripts/update-card-rules.sh [--check] <url-or-file>` — default source `https://checkout.sunbay.us/api/card/rules`. Without `--check`: fetch (or copy), verify it is valid JSON with `schemaVersion`, write the bundled file byte-for-byte, print the SHA-256. With `--check`: exit 1 and print both hashes if the bundled file's SHA-256 differs from the source's (for CI), exit 0 otherwise. Never edits content.

- [ ] **Step 1: Write failing tests** (they load `CardRulesProvider.bundled`, so they validate the real shipped document) from contract §6:
  - Formatting table: `PANFormatter.format(digits, rules: set.rules(forScheme: scheme))` for the seven rows (`visa 4242…`, 19-digit visa, `amex 378282246310005`, `dinersclub 36227206271667` and `3622720627166712`, `unionpay 6222021234567890123`, no scheme `12345678901234567`).
  - Prefix table with `detectScheme`: `4→visa`, `34/37→amex`, `51/55/2221/2720→mastercard`, `3→nil`, `36→dinersclub`, `6011→discover`, `3528→jcb`, `620→unionpay`.
  - Auto-advance: `rules(forScheme: "amex").autoAdvanceLength == 15`, `mastercard == 16`.
  - `test_bundled_hasNoOverlapBetweenDiscoverAndUnionpayPrefixes` (the 6221…/6011/644–649/65 cases resolve to the expected scheme).
  - `test_bundled_parsesAndIsNotTheDraft` (`version != "draft-bundled-1"`).
- [ ] **Step 2: Run** `swift test --filter CardRulesContractVectorsTests`. Expected: FAIL (draft bundle has no `dinersclub` mismatch issues but its version is the draft; the formatting vectors may already pass — that is fine, the version test must fail).
- [ ] **Step 3: Implement** the script; then run it: `scripts/update-card-rules.sh https://checkout.sunbay-dev.com/api/card/rules` (HPP is being deployed; if the live doc still keys `diners`, use `scripts/update-card-rules.sh /Users/sm4267/workspace/web/checkout/src/assets/data/card/brandRules.json` and re-run against the endpoint once the deployment finishes). Then `scripts/update-card-rules.sh --check <same source>` exits 0.
- [ ] **Step 4: Run** `swift test` and fix any existing tests that depended on the draft bundle (the draft had `maestro` / `mir` and `autoAdvanceLength` on every brand): adjust those tests to inject their own `CardRuleSet` instead of relying on the bundle.
- [ ] **Step 5: Commit** the script, JSON and test — `feat(card-rules): ship the HPP rules document as the bundled copy`.

### Task 6: Documentation

**Files:**
- Modify: `docs/card-rules-contract.md` §4.1 (cadence: at most one check per hour per process, evaluated when a card form is built; scheme key for Diners is `dinersclub`; native bundled copy comes from `scripts/update-card-rules.sh`), `docs/product-spec.md` §7 (rules endpoint moves from mock baseline to real; BIN stays "not wired, by decision"), `docs/real-api-integration-checklist.md` §1 (tick 1.1 adapters and 1.2 networking for rules; rewrite 1.1's "make protocols public" item as "decided: stay internal"; keep every BIN item open and mark them deferred; tick 1.3 first two bullets; add the `diners` shim removal as a follow-up), `docs/security-and-pci.md` (the rules request carries no card data, the cache is public and lives in `Caches`; state that no BIN is sent), `AGENTS.md` §3 one line adding `Core/CardBrand/` rules sync if absent.

- [ ] **Step 1: Edit** the files above; keep English, keep tables consistent with the code.
- [ ] **Step 2: Verify** `grep -rn "dinersclub" docs/card-rules-contract.md` still shows the contract key and `grep -n "once per process" docs` returns nothing stale.
- [ ] **Step 3: Update the DingTalk PCI doc?** No — nothing PCI-relevant changed (no BIN flow). Note this in the final report instead.
- [ ] **Step 4: Commit** the docs — `docs(card-rules): rules sync cadence, decisions and checklist`.

---

## Self-review

- Spec coverage: HTTP adapter (T2), trigger in both shells (T4), gated cadence (T3), invalid-document handling (T3), bundled doc + script + drift check (T5), `diners` shim (T1), docs/contract updates (T6), BIN dormant (Global Constraints, T4 "do not touch"). The "CI step" is the script's `--check` mode; this repo has no CI config, so hooking it up is the owner's call.
- Type consistency: `CardRulesRefreshGate.claim(now:)`, `refreshInBackground(service:store:gate:)`, `getRaw`, `HTTPCardRulesService(client:)`, `cardRulesService` names are used identically across tasks.
- Known risk: replacing the bundle (T5) may break tests that assumed draft content; T5 step 4 covers it.
