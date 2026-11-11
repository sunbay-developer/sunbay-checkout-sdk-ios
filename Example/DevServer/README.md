# DevServer

**DEV ONLY. This server holds merchant API credentials. In production, create the session in YOUR backend; never put the API key in an app.**

A dependency-free Node (>=20.6) server that creates checkout sessions for the iOS Example app and real-API tests.

## Setup

```
cp .env.example .env.local   # then fill in API_KEY / APP_ID / MERCHANT_ID
node server.mjs
node --test "test/*.test.mjs"
```

## Endpoints

- `POST /api/create-session` body `{amount?, taxAmount? (default 0), customerId? (default `CUSTOMER_ID`), items?, currency?, collectBillingAddress?, collectShippingAddress?, supportStoreCard? (default true)}` (amount and taxAmount in major units; no tax is added automatically) returns `{sessionId, checkoutClientSecret, customerAccessSecret|null}`.
- `GET /healthz` returns `{ok, hasCredentials, warning}`.

Binds `HOST` (default `0.0.0.0`, LAN-reachable so a real device can connect) and `PORT` (default 8095).
On start it prints the loopback and LAN URLs. This exposes an unauthenticated, credential-backed
endpoint on the network: use a trusted network only, or set `HOST=127.0.0.1` to keep it on loopback.

## Logs

The server prints one timestamped line per request and, for `create-session`, the incoming request, the
upstream request (business fields only) and the upstream response (`code`, `msg`, `traceId`, `sessionId`,
`expiresAt`). The API key and the `Authorization` header are never logged; `checkoutClientSecret` and
`customerAccessSecret` are masked to their prefix plus the last 4 characters (for example `ccs_…08f3`) so
a log line can be matched with what the app received. Use the `traceId` when asking the backend team.
