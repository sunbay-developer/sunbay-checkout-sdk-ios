# attemptId on the wire: iOS SDK Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Send `attemptId` in every `/payment/submit` request body, and send it on result queries that follow a submit.

**Architecture:** `CheckoutController` already mints a `UUID` per confirm and carries it in `SubmitRequest.attemptId`, but `HTTPPaymentService.SubmitBody` drops it. Add it to the body. Add a non-breaking `getResult(sessionId:attemptId:)` to the public `PaymentService` protocol (default implementation forwards to `getResult(sessionId:)`), implement it in `HTTPPaymentService`, and call it from the controller.

**Tech Stack:** Swift 5, SwiftPM, XCTest.

**Spec:** `checkout-hosted/docs/superpowers/specs/2026-11-19-attempt-id-design.md` (§5.5, §5.4). Hosted side plan: `checkout-hosted/docs/superpowers/plans/2026-11-19-attempt-id.md`.

## Global Constraints

- English only in code, comments, docs and commit messages.
- Public API change: follow `AGENTS.md` §2a. Update `docs/api/` and the Example; then check `showcase/sdk-for-ios` (own branch and commit, only if it uses the changed API; run its tests only if it changed).
- Wire value: `attemptId` is the UUID as a lowercase-or-uppercase string via `uuidString`; the backend treats it as an opaque string.
- Every confirm mints a new attemptId. Never reuse one.
- Do not commit unless the user asks. Branch from `main`, name `fix/attempt-id`.

## Review Focus

- The submit body JSON contains `attemptId` for all three paths (new card, wallet, saved card). (Task 1)
- A result query after a submit sends the same attemptId; a query with no known attempt (host `retrievePayment` after a process restart) sends only the session. (Task 2)
- Result query for an attempt that returns `EXPIRED` with no `txnStatus` surfaces as an unknown outcome, never as a failed payment. (Task 2)
- Existing host `PaymentService` implementations keep compiling. (Task 2)

---

### Task 1: Send attemptId in the submit body

**Files:**
- Modify: `Sources/SunbayCheckout/Core/Network/HTTPPaymentService.swift` (`SubmitBody` ~line 69, `submit` ~line 121)
- Test: `Tests/SunbayCheckoutTests/Core/HTTPPaymentServiceTests.swift`

**Interfaces:**
- Produces: `SubmitBody.attemptId: String` set from `req.attemptId.uuidString`.

- [ ] **Step 1: Write the failing test** `testSubmitBodyIncludesAttemptId` in `HTTPPaymentServiceTests`. Use the existing stub transport to capture the request body. Submit a `SubmitRequest` with a fixed `attemptId` UUID and assert the decoded JSON has `attemptId == fixedUUID.uuidString`. Add the same assertion for a wallet request and a saved-card request (`paymentMethod == "TOKEN"`).
- [ ] **Step 2: Run to verify it fails:** `swift test --filter HTTPPaymentServiceTests/testSubmitBodyIncludesAttemptId`. Expected: FAIL (key missing).
- [ ] **Step 3: Implement.** Add `let attemptId: String` to `SubmitBody` and pass `req.attemptId.uuidString` in `submit`.
- [ ] **Step 4: Run to verify it passes:** same command, expected PASS.

### Task 2: Query the result with the attemptId

**Files:**
- Modify: `Sources/SunbayCheckout/Core/PaymentService.swift` (protocol, ~line 104)
- Modify: `Sources/SunbayCheckout/Core/Network/HTTPPaymentService.swift` (`getResult` ~line 142, `accept` ~line 158)
- Modify: `Sources/SunbayCheckout/Core/Network/SunbayEndpoints.swift` only if the body type needs a new struct (it should not)
- Modify: `Sources/SunbayCheckout/Core/CheckoutController.swift` (`submitAndResolve` ~line 599, `retrievePayment` ~line 483, and a new `lastAttemptId` property)
- Modify: `Sources/SunbayCheckoutTestSupport/ScriptablePaymentService.swift`, `Tests/SunbayCheckoutTests/Support/MockPaymentService.swift` (record the attemptId of `getResult` calls)
- Test: `Tests/SunbayCheckoutTests/Core/HTTPPaymentServiceTests.swift`, `Tests/SunbayCheckoutTests/Core/CheckoutControllerTests.swift`

**Interfaces:**
- Produces on `PaymentService`: `func getResult(sessionId: String, attemptId: UUID) async throws -> PaymentSnapshot`, with a default implementation in a protocol extension that calls `getResult(sessionId:)`. The existing requirement stays.
- Produces in `HTTPPaymentService`: override of the new method. Body `ResultBody { let attemptId: String }`, posted to `.paymentResult(sessionId:)`. The existing `getResult(sessionId:)` keeps sending an empty body.
- Produces in `CheckoutController`: `private var lastAttemptId: UUID?`, set in each `confirm*` when the attempt id is minted. `retrievePayment(sessionId:)` calls the new method when `lastAttemptId` is non-nil, otherwise the old one. `lastAttemptId` is cleared in `dismiss()` and on success.
- Behaviour: when a result query was made with an attemptId and the response has `status == "EXPIRED"` and no `txnStatus`, `HTTPPaymentService` throws a `CheckoutError` with code `PAYMENT_OUTCOME_UNKNOWN` (category `.network`, message "The payment result could not be confirmed."), not the session-expired error. The query without an attemptId keeps the current behaviour.

- [ ] **Step 1: Write the failing tests:**
  - `HTTPPaymentServiceTests.testGetResultWithAttemptIdSendsAttemptIdInBody`: body JSON equals `{"attemptId": "<uuid>"}`.
  - `testGetResultWithoutAttemptIdSendsEmptyBody`: unchanged behaviour, body `{}`.
  - `testGetResultWithAttemptIdExpiredWithoutTxnStatusThrowsOutcomeUnknown`: response `{"code":"0","data":{"status":"EXPIRED","sessionId":"s1","supportStoreCard":false}}` throws code `PAYMENT_OUTCOME_UNKNOWN`. The same response through `getResult(sessionId:)` still throws the session-expired error.
  - `CheckoutControllerTests.testSubmitFailureQueriesWithTheSameAttemptId`: submit throws a network error, then assert the scripted service's recorded `getResult` attemptId equals the `SubmitRequest.attemptId` of the failed submit, and the outcome is `.unknown` when that query throws.
  - `testRetrievePaymentUsesLastAttemptIdAfterConfirm` and `testRetrievePaymentWithoutAttemptUsesSessionOnly`.
- [ ] **Step 2: Run to verify they fail:** `swift test --filter "HTTPPaymentServiceTests|CheckoutControllerTests"`. Expected: the new tests fail, existing ones pass.
- [ ] **Step 3: Implement** per Interfaces. In `accept`, add a parameter `queriedAttempt: Bool` (default false) that selects the `PAYMENT_OUTCOME_UNKNOWN` error for the EXPIRED-without-txn case.
- [ ] **Step 4: Run the full suite:** `swift test`. Expected: all pass.

### Task 3: Docs and consumers

**Files:**
- Modify: `docs/api/` (the `PaymentService` page), `docs/product-spec.md` (§8 item 3 and the idempotency row), `docs/superpowers/BACKLOG.md`, `docs/superpowers/specs/2026-11-09-real-api-integration-design.md` (line 101, "attemptId stays an SDK-local in-flight guard only")
- Check: `Example/`, `showcase/sdk-for-ios` (path `../../../showcase/sdk-for-ios` from this repo)

- [ ] **Step 1:** Update the docs above: `attemptId` is now sent on submit and on follow-up result queries; each confirm mints a new id; `PAYMENT_OUTCOME_UNKNOWN` is documented.
- [ ] **Step 2:** `grep -rn "getResult(" Example ../../../showcase/sdk-for-ios --include=*.swift`. If a host implementation exists, it keeps compiling because of the default implementation; no change needed. Report the result.
- [ ] **Step 3:** Run `swift test` once more and report.

## Known gap, needs a decision before or after this plan

`BACKLOG.md` says the "never resubmit after `.pending` / `.unknown`" gate (commit `4cbada0`, `PendingReconciliationStore`) is fixed. That commit is an ancestor of `main`, but `git grep PendingReconciliationStore main -- Sources` finds nothing: the Core gate is not in the current code. Only the UI-side locked `.reconciling` state remains. With a new attemptId on every confirm, the backend can no longer dedupe a repeat tap, so the Core gate is what prevents a double charge. This plan does not rebuild it. Ask the user whether to restore it as a separate task.
