# Card brand rules & BIN recognition — API contract

Status: DRAFT for the HPP implementation. This is the single contract that the HPP server (web
checkout), the HPP front end, the iOS SDK and the Android SDK all build against. The HPP server is
the source of truth for the rules; every client keeps a bundled fallback copy.

## 1. Purpose and principles

Card inputs behave differently per card brand: number length, display grouping, security-code name
and length. This contract defines (a) a **rules document** describing those per-brand behaviors, and
(b) a **BIN recognition** endpoint.

Principles (non-negotiable, they shape every rule below):

1. **Rules are hints, not enforcement.** The payment backend is the final validator. A wrong or stale
   rule may make formatting less pretty; it must never stop a user from entering a valid card.
2. **Hard input limits are universal, never brand-specific:** card number at most 19 digits, security
   code at most 4 digits. Brand lengths drive grouping, auto-advance and display only.
3. **Client-side validation is lenient:** reject only the impossible (number outside 12–19 digits,
   security code not 3 or 4 digits). Do not enforce brand lengths. Enforce Luhn at submit for every
   card **except UnionPay** (some UnionPay cards are not Luhn-valid); an unrecognized brand is
   checked too. Everything else is left to the backend.
4. **The rule set always works offline.** Clients ship a bundled copy; the network only refreshes it.
5. **Backend recognition wins on conflict.** When the BIN endpoint returns a scheme, it overrides the
   scheme guessed locally from the rules' prefix patterns.
6. **No card data in logs, analytics or crash reports.** A BIN (first 6–9 digits) is treated as
   sensitive: never logged, never persisted, sent only over TLS.

## 2. Rules document

A static JSON document, served as-is (no `{code,msg,data}` envelope).

```json
{
  "schemaVersion": 1,
  "version": "2026-11-07.1",
  "generic": {
    "groups": [4, 4, 4, 4],
    "minLength": 12,
    "maxLength": 19,
    "cvv": { "name": "CVC", "sizes": [3, 4] }
  },
  "brands": [
    {
      "scheme": "visa",
      "displayName": "Visa",
      "patterns": [4],
      "lengths": [16, 18, 19],
      "groups": [4, 4, 4, 4],
      "cvv": { "name": "CVV", "sizes": [3] },
      "autoAdvanceLength": 19
    },
    {
      "scheme": "amex",
      "displayName": "American Express",
      "patterns": [34, 37],
      "lengths": [15],
      "groups": [4, 6, 5],
      "cvv": { "name": "CID", "sizes": [4] },
      "autoAdvanceLength": 15
    },
    {
      "scheme": "dinersclub",
      "displayName": "Diners Club",
      "patterns": [[300, 305], 36, 38, 39],
      "lengths": [14, 16, 19],
      "groups": [4, 6, 4],
      "groupsByLength": { "16": [4, 4, 4, 4], "19": [4, 4, 4, 4] },
      "cvv": { "name": "CVV", "sizes": [3] }
    }
  ]
}
```

Fields:

| Field | Meaning |
|---|---|
| `schemaVersion` | Integer. Bumped only for incompatible changes. A client that does not know the value ignores the document and keeps what it has. |
| `version` | Opaque string for humans/diagnostics (date plus counter). Clients do not compare it. |
| `generic` | Rules used when no brand matches. |
| `brands[].scheme` | Lower-case key. Must equal the lower-cased `cardScheme` the BIN endpoint returns. The backend returns exactly `VISA MASTERCARD AMEX DISCOVER JCB DINERSCLUB UNIONPAY`, or `null` when unrecognized, so those seven keys are `visa mastercard amex discover jcb dinersclub unionpay`. Rules may define more brands (for example `maestro elo mir`); the backend never returns those, so they are only ever matched locally from the prefix patterns. |
| `brands[].patterns` | Prefix matchers. A number is a prefix (`4`, `34`). `[a, b]` is an inclusive range of prefixes (`[51, 55]`, `[2221, 2720]`). |
| `brands[].lengths` | Valid PAN lengths. Informational (see principle 3). |
| `brands[].groups` | Group sizes for display, e.g. `[4,6,5]` renders `3782 822463 10005`. Digits beyond the sum are grouped by 4. |
| `brands[].groupsByLength` | Optional per-length override of `groups` (key = digit count as string). The override applies once the typed length is at least the key; otherwise `groups` applies. |
| `brands[].cvv.name` | Brand's own name for the code (CVV, CVC, CID, CVN2…). English clients use it as the security-code field label, so the label follows the recognized brand (Visa → "CVV"); `generic.cvv.name` ("CVC") is the default before any brand is known. Localized UIs may keep their own word (zh: 安全码). |
| `brands[].cvv.sizes` | The code lengths this brand normally uses. **A hint only**: it drives the placeholder example (`123` / `1234`). It is not enforced — typing is capped at 4 and submission accepts 3 or 4 for every brand (section 4.3). |
| `brands[].autoAdvanceLength` | Optional. When the digit count reaches it, focus moves to the next field. **Set it to the largest value in `lengths`** (Visa 19, Amex 15, Mastercard 16, …). Nobody can type past the 19-digit universal cap, so a focus jump at a brand's maximum length can never hijack a legitimate longer number. Do not set it to a shorter length for brands whose length varies. Consequence: a 16-digit Visa does not auto-advance (only a 19-digit one does); this is accepted. |

Sanity bounds a client applies when loading a document, discarding it (keeping the previous rules)
if any check fails: `schemaVersion` known; every length in 12–19; every group size 1–19 and
`sum(groups) <= 19`; `cvv.sizes` values in {3, 4}; at most 64 brands; document size under 256 KB.

### 2.1 Prefix matching

Given the digits typed so far (`typed`, at least 1 digit), for each pattern with prefix length `L`:

- `t` = the first `min(L, typed.length)` digits of `typed`, as an integer.
- For a range `[a, b]`: `lo` and `hi` = the first `min(L, typed.length)` digits of `a` and `b`.
  For a single prefix `p`, `lo = hi` = the first `min(L, typed.length)` digits of `p`.
- The pattern **matches** when `lo <= t <= hi`. It is a **full match** when `typed.length >= L`,
  otherwise a **partial match**.

Selecting the scheme:

1. If any brand has a full match, pick the brand whose full-matching pattern has the largest `L`
   (ties: the earlier brand in the document).
2. Otherwise, if exactly one brand has a partial match, pick it.
3. Otherwise there is no scheme: use `generic`.

Known and accepted: very short prefixes can flicker (e.g. `62` resolves to a broad pattern until a
longer UnionPay prefix is typed). The BIN endpoint result replaces the local guess at 6 digits.

### 2.2 Display grouping

Using the selected rules: `groups = groupsByLength[k]` for the largest key `k <= digitCount` that
exists, else `groups`. Take the first `groups[0]` digits, then `groups[1]`, …; digits beyond
`sum(groups)` are grouped by 4. Separate groups with one space. Re-grouping on a scheme change
**never deletes digits**.

### 2.3 Auto-advance

Move to the next field when `scheme` is known, `autoAdvanceLength` is present, and the digit count
equals it. Only when the caret is at the end of the number (editing a digit in the middle never
moves focus). With no known scheme, a client may fall back to its own heuristics.

## 3. Endpoints (HPP server)

Both follow the HPP conventions of `src/app/api/address/*` (Next.js route handlers).

### 3.1 `GET /api/card/rules`

Returns the rules document (section 2).

- Source: a JSON file in the HPP repo (for example `src/assets/data/card/brandRules.json`), bundled
  with the server. The same file is the default fallback. If rules later move to a managed store,
  read from the store with an in-memory cache and **fall back to this file on any failure**; the
  response format does not change.
- `ETag`: strong ETag = SHA-256 of the document bytes. Compute once at load.
- `Cache-Control: public, max-age=300, stale-while-revalidate=86400`.
- Conditional requests: if `If-None-Match` equals the current ETag, respond `304 Not Modified` with no
  body.
- Errors use the standard envelope: `{ "code": "...", "msg": "...", "data": null, "traceId": "..." }`.
  Clients treat any non-200/304 response as "no update".
- Public and unauthenticated (no sensitive data). Rate limiting is a deployment concern (gateway/CDN), not implemented in the route.

### 3.2 `POST /api/card/bin`

Request body:

```json
{ "bin": "424242", "sessionId": "..." }
```

- `bin`: 6–9 digits. Reject anything else with a 4xx. Never accept a full PAN.
- `sessionId`: the checkout session id; used by the server when it calls the backend's recognition.

Response (standard HPP envelope, `code: "0"`):

```json
{ "code": "0", "msg": "success", "traceId": "...",
  "data": { "scheme": "visa", "cardType": "CREDIT", "issuerName": "..." } }
```

- `scheme` is lower-case and equals a `brands[].scheme` key, or `null` when unrecognized.
  `cardType` and `issuerName` may be `null`.
- The server calls the backend (`/checkout/web/card/bin/recognize`) internally; clients never call
  the backend directly. On backend failure the server returns `scheme: null` rather than an error
  where possible, so clients degrade to local matching.
- Rate limiting, if any, is applied at the gateway; clients must treat `429` as "stop looking up for this session". **Do not log `bin`.**

## 4. Client behavior

### 4.1 Rules lifecycle

1. On card component display: use the **cached** document if one exists, else the **bundled** one.
2. In the background send one conditional `GET /api/card/rules` (with the stored ETag). At most once
   per process / page load.
3. On `200` with a valid document: store body and ETag, and use it **the next time the component is
   shown** (not in the middle of typing). On `304`, a failure, an invalid document or an unknown
   `schemaVersion`: keep the current rules.
4. Precedence: cached remote > bundled. Never block input on the network.

Native SDKs: cache in the OS cache directory (purgeable); the data is public and non-sensitive.
HPP front end: ships the rules statically in its bundle and does not fetch them. This is equivalent
to the native flow because the bundle and `GET /api/card/rules` are built from the same repo JSON;
changing a rule means redeploying HPP.

### 4.2 BIN recognition triggers

- Fewer than 6 digits: cancel any in-flight lookup; drop the BIN-derived scheme (fall back to local
  prefix matching).
- Query at exactly 6 digits and at exactly 9 digits (the 9-digit BIN refines the result).
- At 7 or 8 digits (or more than 9), query only if no scheme is known yet.
- If the first 6 digits change after a scheme was resolved, drop the scheme and query again.
- Debounce ~300 ms; ignore stale responses (keep a sequence number).
- Cache results per BIN in memory for the session, **including "unrecognized"** answers, so retyping
  a BIN costs no request. A `null` result keeps the current scheme.
- **The server does not rate-limit, so clients throttle themselves:** at most 20 lookups per session
  (one session = one checkout screen), and no more lookups for the rest of the session after a `429`
  or after 3 consecutive failures. Rules are fetched at most once per process / page load.
- Any failure is silent: stay on local matching.

### 4.3 Validation (lenient)

Block submission only when: number is outside 12–19 digits; number fails Luhn (UnionPay exempt);
security code is not 3 or 4 digits (the same for every brand, never tighter);
expiry is invalid or expired. Show the backend's error for everything else.

## 5. Bundled copy and drift

The HPP repo JSON is the source of truth.

- **HPP:** the repo JSON is the server fallback.
- **iOS / Android:** a copy ships inside the SDK. A release script overwrites it from the live
  endpoint at build time, and CI compares the copy's SHA-256 against the live ETag and warns on
  drift. The copy is never edited by hand.

Seeding the full document is a one-off on the HPP side. A suggested source is the open-source
`credit-card-type` package (MIT, to be license-checked before use), which carries patterns, gaps,
lengths and code names per brand; convert its `gaps` to `groups` and review the result against the
brands the backend actually supports.

## 6. Test vectors

Formatting (scheme, digits, expected display):

| scheme | digits | display |
|---|---|---|
| visa | `4242424242424242` | `4242 4242 4242 4242` |
| visa | `4242424242424242424` | `4242 4242 4242 4242 424` |
| amex | `378282246310005` | `3782 822463 10005` |
| dinersclub | `36227206271667` | `3622 720627 1667` |
| dinersclub | `3622720627166712` | `3622 7206 2716 6712` |
| unionpay | `6222021234567890123` | `6222 0212 3456 7890 123` |
| (none) | `12345678901234567` | `1234 5678 9012 3456 7` |

Prefix matching (with the full production document, digits typed so far, expected scheme):

| typed | scheme |
|---|---|
| `4` | visa |
| `34`, `37` | amex |
| `51`, `55`, `2221`, `2720` | mastercard |
| `3` | none (ambiguous) |
| `36` | dinersclub |
| `6011` | discover |
| `3528` | jcb |
| `620` | unionpay |

Auto-advance (number field, caret at the end, typing or pasting):

| scheme | digits typed | advances? |
|---|---|---|
| visa | 16 | no |
| visa | 19 | yes |
| amex | 15 | yes |
| mastercard | 16 | yes |
| (none) | any | per the client's own fallback |

Security code (hints only — not validation): the example placeholder is `1234` for a brand whose
`cvv.sizes` includes 4 (Amex) and `123` otherwise. Typing is capped at 4 digits for every brand, and
submission accepts 3 or 4 digits for every brand (section 4.3); a brand's `cvv.sizes` is never used to
reject a code, because a misrecognized brand must not block a valid card.

## 7. Input interaction behaviors

These are UX rules, not data. They make the three inputs feel the same on every platform. Examples use
the iOS implementation's test cases; "caret" is the text cursor, offsets are in UTF-16 units.

### 7.1 Card number

- **Format as you type** with the selected rules (section 2.2). Non-digits are dropped; at most 19 digits.
- **Backspace over a separator.** If the edit removed only a group separator (the digit string did not
  change), delete the digit just before that separator instead. Otherwise formatting re-adds the
  space and the key looks dead.
  `4242 4` with the caret after the space, Backspace → `4244`, caret after the 3rd digit.
- **Caret stays beside the same digit** when you insert or delete in the middle. Only when the edit is
  at the end does the caret go to the end.
  `4242 4242`, type `9` at offset 2 → `4294 2424 2`, caret at offset 3.
- **Paste.** Strip every non-digit (spaces, dashes), keep at most 19 digits, format, put the caret at
  the end. `4242-4242 4242 4242 4242 99` → `4242 4242 4242 4242 424`.
- **Scheme change re-formats without losing digits** and keeps the caret beside the same digit
  (for example the backend result arrives while the user is typing).
  `3782 8224 6310 005` with the Amex rules → `3782 822463 10005`, caret unchanged at offset 4.

### 7.2 Expiry (`MM/YY`)

- **Digits only, at most 4.** The field shows `MM/YY`; the `/` is inserted automatically as soon as
  the month is complete (`12` → `12/`).
- **First digit 2–9 pads the month:** `5` → `05/`. First digit `0` or `1` waits for the second.
- **Month range is enforced while typing.** A month outside 01–12 is rejected (`00`, `13` cannot be
  typed).
- **Backspace over the `/`** deletes the digit before it (same reason as 7.1).
- **Caret stays beside the same digit** on edits in the middle.
- **Paste.** `0828`, `08/28`, `082028` and `08/2028` all become `08/28` (a pasted year starting with
  `20` keeps its last two digits).
- **Submit value.** Month is the two digits; year is `"20" + YY` (4 digits) — the backend contract.
  An expired month (before the current month of the current year) blocks submission.

### 7.3 Focus movement

- **Number → expiry** when the digit count equals the brand's `autoAdvanceLength` (section 2.3).
  With no known brand the client may use its own local heuristic (iOS: a fixed-length brand prefix
  and a valid Luhn checksum).
- **Expiry → security code** when the expiry holds a complete, month-valid `MM/YY`.
- **Both only when typing or pasting with the caret at the end.** Editing a digit in the middle never
  moves focus.
- **Backspace in an empty field moves back:** empty expiry → number, empty security code → expiry.

### 7.4 Security code

- Digits only, at most 4 regardless of the brand (principle 2); the stored value is masked.
- The example placeholder follows the brand: `1234` when the brand's `cvv.sizes` allows 4, else `123`.
- The field label is the brand's `cvv.name` in English (default "CVC", Visa "CVV"); other languages may
  keep one word (zh: 安全码).

## 8. Decisions and remaining open points

Decided:

- **Scheme set:** the backend returns `VISA MASTERCARD AMEX DISCOVER JCB DINERSCLUB UNIONPAY` or `null`
  (section 2, `brands[].scheme`). An unknown value must be treated as "no scheme" by every client.
- **`sessionId`:** validated by the backend; HPP passes it through unchanged.
- **Rate limiting:** not done in the route (section 3).
- **Auto-advance:** at the brand's maximum length (`max(lengths)`), so a longer legitimate number is never hijacked; a 16-digit Visa therefore does not advance (section 2).

Still open:

- Whether the backend's `null` for a card it cannot recognize can later include more brands (the rules
  already carry local-only brands such as Maestro, Elo and Mir).
