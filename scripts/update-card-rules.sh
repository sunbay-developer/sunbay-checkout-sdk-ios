#!/usr/bin/env bash
# Refreshes the bundled card-brand rules from the HPP document, or checks that they are in sync.
#
#   scripts/update-card-rules.sh [--check] [<url-or-file>]
#
# <url-or-file>  Where the HPP document comes from. Default: the production endpoint.
# --check        Do not write. Exit 1 (printing both SHA-256 values) if the bundled file differs from the
#                source; exit 0 if identical. Intended for CI drift warnings.
#
# The bundled file must never be edited by hand. It is stored in the compact form HPP serves
# (`JSON.stringify`, no whitespace), so its SHA-256 equals the live endpoint's ETag no matter whether the
# source is the URL or the pretty-printed file in the HPP repo.
set -euo pipefail

DEFAULT_SOURCE="https://checkout.sunbay.us/api/card/rules"
BUNDLED="$(cd "$(dirname "$0")/.." && pwd)/Sources/SunbayCheckout/Resources/CardRules/card-brand-rules.json"

check=0
if [[ "${1:-}" == "--check" ]]; then
  check=1
  shift
fi
source_arg="${1:-$DEFAULT_SOURCE}"

tmp="$(mktemp)"
trap 'rm -f "$tmp"' EXIT

if [[ "$source_arg" =~ ^https:// ]]; then
  curl --fail --silent --show-error --max-time 15 "$source_arg" -o "$tmp"
elif [[ -f "$source_arg" ]]; then
  cp "$source_arg" "$tmp"
else
  echo "error: source must be an https URL or an existing file: $source_arg" >&2
  exit 2
fi

# Validate (a JSON object with a schemaVersion and a brands array) and rewrite in place in the compact
# form HPP serves.
python3 - "$tmp" <<'PY'
import json, sys
path = sys.argv[1]
doc = json.load(open(path, encoding="utf-8"))
assert isinstance(doc, dict) and "schemaVersion" in doc and isinstance(doc.get("brands"), list), \
    "not a card rules document"
with open(path, "w", encoding="utf-8", newline="") as out:
    out.write(json.dumps(doc, separators=(",", ":"), ensure_ascii=False))
PY

new_sha="$(shasum -a 256 "$tmp" | cut -d' ' -f1)"
old_sha="$( [[ -f "$BUNDLED" ]] && shasum -a 256 "$BUNDLED" | cut -d' ' -f1 || echo none )"

if [[ $check -eq 1 ]]; then
  if [[ "$new_sha" == "$old_sha" ]]; then
    echo "card rules in sync ($new_sha)"
    exit 0
  fi
  echo "card rules DRIFT: bundled=$old_sha source=$new_sha" >&2
  exit 1
fi

cp "$tmp" "$BUNDLED"
echo "bundled card rules updated: $old_sha -> $new_sha"
