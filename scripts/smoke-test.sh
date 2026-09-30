#!/usr/bin/env bash
#
# Post-deploy checks against a running instance. Deliberately black-box: they
# prove the deployed site actually serves, not that the code compiles — CI
# already covers that.
#
#   scripts/smoke-test.sh https://staging.example.com
#
# Optional: EXPECT_SHA=<commit> also checks the page reports that release, so
# a deploy that "succeeded" onto the wrong build is caught.
#
set -uo pipefail

BASE_URL="${1:?usage: smoke-test.sh <base-url>}"
BASE_URL="${BASE_URL%/}"
CURL=(curl --silent --show-error --max-time 20 --location)

PASS=0
FAIL=0

ok()  { printf '  \033[32mPASS\033[0m %s\n' "$1"; PASS=$((PASS + 1)); }
bad() { printf '  \033[31mFAIL\033[0m %s\n' "$1"; FAIL=$((FAIL + 1)); }

check_status() {
  local label="$1" path="$2" expected="$3" got
  got=$("${CURL[@]}" -o /dev/null -w '%{http_code}' "$BASE_URL$path" 2>/dev/null)
  if [ "$got" = "$expected" ]; then ok "$label ($path -> $got)"
  else bad "$label ($path -> got $got, want $expected)"; fi
}

check_contains() {
  local label="$1" path="$2" needle="$3" body
  # Capture first, then match. Piping straight into `grep -q` makes grep exit
  # on the first match, curl dies of SIGPIPE, and pipefail reports a failure
  # even though the content was there.
  body=$("${CURL[@]}" "$BASE_URL$path" 2>/dev/null)
  if printf '%s' "$body" | grep -q -- "$needle"; then ok "$label"
  else bad "$label (response from $path did not contain '$needle')"; fi
}

echo "Smoke-testing $BASE_URL"

# 1. The framework is up at all: Laravel's built-in health route.
check_status "health endpoint" /up 200

# 2. The page renders: PHP, the session store and the view layer all work.
check_status "home page renders" / 200
check_contains "home page is the app, not an error page" / 'data-app="demo"'

# 3. The built frontend is served. A deploy that skipped `npm run build`
#    leaves a page that answers 200 and is broken in the browser.
MANIFEST=$("${CURL[@]}" "$BASE_URL/build/manifest.json" 2>/dev/null)
if printf '%s' "$MANIFEST" | grep -q '"file"'; then
  ok "vite manifest is served"
  ASSET=$(printf '%s' "$MANIFEST" | grep -oE '"file"[[:space:]]*:[[:space:]]*"[^"]*"' | head -1 | sed 's/.*"\([^"]*\)"$/\1/')
  [ -z "$ASSET" ] || check_status "hashed asset from manifest is served" "/build/$ASSET" 200
else
  bad "vite manifest missing or malformed at /build/manifest.json"
fi

# 4. Debug mode must never be on where the public can reach it.
NOT_FOUND=$("${CURL[@]}" "$BASE_URL/__smoke_test_missing_route_$$" 2>/dev/null)
if [ -z "$NOT_FOUND" ]; then
  # No body means the host is unreachable, not that it is safe.
  bad "error page check got no response from $BASE_URL"
elif printf '%s' "$NOT_FOUND" | grep -qiE 'APP_KEY|DB_PASSWORD|vendor/laravel/framework|Whoops'; then
  bad "error page leaks internals — APP_DEBUG is likely true"
else
  ok "error page does not leak internals"
fi

# 5. The release that is live is the one that was deployed.
if [ -n "${EXPECT_SHA:-}" ]; then
  check_contains "the live release is $EXPECT_SHA" / "$EXPECT_SHA"
fi

echo
echo "  $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
