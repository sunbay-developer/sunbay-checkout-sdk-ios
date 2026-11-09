#!/usr/bin/env bash
# DEV ONLY. Starts Example/DevServer on a free port and runs the opt-in real-API tests against it.
# Never prints credentials.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

PORT="$(python3 -c 'import socket; s=socket.socket(); s.bind(("127.0.0.1",0)); print(s.getsockname()[1]); s.close()')"
LOG="$(mktemp "${TMPDIR:-/tmp}/sunbay-devserver.XXXXXX")"

PORT="$PORT" node Example/DevServer/server.mjs >"$LOG" 2>&1 &
SERVER_PID=$!
cleanup() {
    kill "$SERVER_PID" 2>/dev/null || true
    wait "$SERVER_PID" 2>/dev/null || true
    rm -f "$LOG"
}
trap cleanup EXIT
trap 'exit 130' INT TERM

HEALTH=""
for _ in $(seq 1 50); do
    if ! kill -0 "$SERVER_PID" 2>/dev/null; then
        echo "Dev server exited early." >&2
        exit 1
    fi
    if HEALTH="$(curl -fsS "http://127.0.0.1:$PORT/healthz" 2>/dev/null)"; then
        break
    fi
    HEALTH=""
    sleep 0.2
done

if [ -z "$HEALTH" ]; then
    echo "Dev server did not become healthy within 10 seconds." >&2
    exit 1
fi
if ! printf '%s' "$HEALTH" | grep -q '"hasCredentials":true'; then
    echo "Dev server reports hasCredentials=false; fill Example/DevServer/.env.local." >&2
    exit 1
fi

SUNBAY_DEV_SERVER_URL="http://127.0.0.1:$PORT" swift test --filter SunbayCheckoutRealAPITests
