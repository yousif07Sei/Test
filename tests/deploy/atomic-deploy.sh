#!/usr/bin/env bash
#
# End-to-end test of scripts/app-deploy (and scripts/build-release.sh)
# against a throwaway releases layout. It runs the real scripts: a real CI-style
# build published as refs/builds/<sha> to a stand-in "GitHub" remote, real git
# archive, a real Laravel boot, real migrations on a SQLite file, and a real
# HTTP /up served from `current` by php -S. Only systemd, npm and chown are off.
#
#   tests/deploy/atomic-deploy.sh            # from the repo root
#
# What it proves:
#   1. a deploy unpacks CI's build: no composer on the box (a composer that
#      fails is first on PATH), and the release carries the build's BUILD file
#   2. a second deploy switches to a new release
#   3. a commit that cannot boot never gets a build, so it cannot be deployed;
#      and built on the box with --build-here it fails BEFORE the switch, with
#      `current` untouched and the broken release removed
#   4. rollback switches to the previous release
#   5. a release that fails its health check AFTER the switch is switched back
#   6. old releases are pruned to KEEP_RELEASES
#   7. --build-here still deploys a commit that has no CI build
#
set -euo pipefail

ROOT=$(cd "$(dirname "$0")/../.." && pwd)
DEPLOY="$ROOT/scripts/app-deploy"
BUILD="$ROOT/scripts/build-release.sh"
T=$(mktemp -d)
PORT=${PORT:-18765}
SERVER_PID=

cleanup() {
  [ -n "$SERVER_PID" ] && kill "$SERVER_PID" 2>/dev/null || true
  rm -rf "$T"
}
trap cleanup EXIT

pass() { printf '  \033[32mPASS\033[0m %s\n' "$*"; }
fail() { printf '  \033[31mFAIL\033[0m %s\n' "$*"; exit 1; }
live() { basename "$(readlink "$APP_DIR/current")"; }
count_releases() { find "$APP_DIR/releases" -mindepth 1 -maxdepth 1 -type d | wc -l; }

export APP_DIR="$T/app"
export RETRY_DELAY=0 SKIP_SERVICES=1 SKIP_FRONTEND=1 SKIP_CHOWN=1
export HEALTH_URL="http://127.0.0.1:$PORT/up"
export KEEP_RELEASES=3

# A composer that fails, first on PATH for deploys that must not build.
mkdir -p "$T/nocomposer"
printf '#!/bin/sh\necho "composer must not run on the box" >&2\nexit 99\n' >"$T/nocomposer/composer"
chmod +x "$T/nocomposer/composer"
deploy_prebuilt() { PATH="$T/nocomposer:$PATH" "$DEPLOY" "$@"; }

# --- a stand-in for GitHub, and commits on it -------------------------------
GH="$T/github.git"
git clone --quiet --bare "$ROOT" "$GH"
WORK="$T/work"
git clone --quiet "$GH" "$WORK"
GOOD=$(git -C "$WORK" rev-parse HEAD)
git -C "$WORK" -c user.name=t -c user.email=t@t commit --quiet --allow-empty -m "same code, new sha"
GOOD2=$(git -C "$WORK" rev-parse HEAD)
git -C "$WORK" -c user.name=t -c user.email=t@t commit --quiet --allow-empty -m "never built by CI"
UNBUILT=$(git -C "$WORK" rev-parse HEAD)
git -C "$WORK" push --quiet origin HEAD:refs/heads/good
# A release that throws while booting: a route file that cannot load.
echo 'throw new RuntimeException("this release does not boot");' >>"$WORK/routes/web.php"
git -C "$WORK" -c user.name=t -c user.email=t@t commit --quiet -am "broken"
BROKEN=$(git -C "$WORK" rev-parse HEAD)
git -C "$WORK" push --quiet origin HEAD:refs/heads/broken

# CI's build step, exactly as ci.yml runs it: a checkout of the commit, then
# build-release.sh --push.
ci_build() {
  local sha="$1" dir="$T/ci-$1"
  git clone --quiet "$GH" "$dir"
  git -C "$dir" checkout --quiet "$sha"
  (cd "$dir" && "$BUILD" --push origin >/dev/null 2>&1)
}

# --- a layout like a cut-over box -------------------------------------------
mkdir -p "$APP_DIR/releases" "$APP_DIR/shared/database"
mkdir -p "$APP_DIR"/shared/storage/{app/public,framework/{cache/data,sessions,views},logs}
git clone --quiet --bare --origin github "$GH" "$APP_DIR/repo.git"
git --git-dir="$APP_DIR/repo.git" config remote.github.fetch '+refs/heads/*:refs/remotes/github/*'

cp "$ROOT/.env.example" "$APP_DIR/shared/.env"
{
  echo "APP_KEY=base64:$(head -c 32 /dev/urandom | base64)"
  echo "APP_ENV=testing"
  echo "APP_URL=http://127.0.0.1:$PORT"
  echo "DB_CONNECTION=sqlite"
  echo "DB_DATABASE=$APP_DIR/shared/database/database.sqlite"
  echo "CACHE_STORE=file"
  echo "SESSION_DRIVER=file"
  echo "QUEUE_CONNECTION=sync"
} >>"$APP_DIR/shared/.env"
touch "$APP_DIR/shared/database/database.sqlite"

cat >"$T/router.php" <<PHP
<?php
\$_SERVER['SCRIPT_FILENAME'] = '$APP_DIR/current/public/index.php';
chdir('$APP_DIR/current/public');
require '$APP_DIR/current/public/index.php';
PHP
php -S "127.0.0.1:$PORT" "$T/router.php" >/dev/null 2>&1 &
SERVER_PID=$!

ci_build "$GOOD" || fail "CI could not build $GOOD"
ci_build "$GOOD2" || fail "CI could not build $GOOD2"

echo "== 1. a deploy unpacks CI's build, and builds nothing"
deploy_prebuilt staging "$GOOD" >/dev/null
R1=$(live)
grep -q "^source   $GOOD" "$APP_DIR/current/BUILD" || fail "the release is not CI's build of $GOOD"
[ -f "$APP_DIR/current/vendor/autoload.php" ] || fail "no vendor/ in the release"
[ -L "$APP_DIR/current/.env" ] && [ -L "$APP_DIR/current/storage" ] || fail ".env and storage are not linked to shared/"
pass "current -> $R1: CI's build, vendor/ included, composer never ran"

sleep 1
echo "== 2. a second deploy switches"
deploy_prebuilt staging "$GOOD2" >/dev/null
R2=$(live)
[ "$R2" != "$R1" ] || fail "current did not move"
pass "current -> $R2"

sleep 1
echo "== 3. a commit that cannot boot never goes live"
if ci_build "$BROKEN"; then fail "CI built a commit that cannot boot"; fi
if deploy_prebuilt staging "$BROKEN" >/dev/null 2>&1; then fail "a commit with no build deployed"; fi
[ "$(live)" = "$R2" ] || fail "current moved to $(live)"
if "$DEPLOY" staging "$BROKEN" --build-here >/dev/null 2>&1; then fail "the broken release deployed with --build-here"; fi
[ "$(live)" = "$R2" ] || fail "current moved to $(live)"
[ "$(count_releases)" = 2 ] || fail "a broken release was left behind"
pass "no CI build; refused. Built here, failed before the switch; current still $R2"

echo "== 4. rollback"
"$DEPLOY" staging rollback >/dev/null
[ "$(live)" = "$R1" ] || fail "rollback went to $(live), not $R1"
pass "current -> $R1"

sleep 1
echo "== 5. a failed health check switches back"
if HEALTH_URL="http://127.0.0.1:1/up" deploy_prebuilt staging "$GOOD" >/dev/null 2>&1; then
  fail "a deploy whose /up fails reported success"
fi
[ "$(live)" = "$R1" ] || fail "current is $(live), not back on $R1"
[ "$(count_releases)" = 2 ] || fail "the unhealthy release was left behind"
pass "switched back to $R1; unhealthy release removed"

echo "== 6. pruning keeps $KEEP_RELEASES"
for _ in 1 2 3; do sleep 1; deploy_prebuilt staging "$GOOD" >/dev/null; done
[ "$(count_releases)" = "$KEEP_RELEASES" ] || fail "expected $KEEP_RELEASES releases, got $(count_releases)"
pass "$(count_releases) releases kept"

sleep 1
echo "== 7. --build-here deploys a commit CI never built"
if deploy_prebuilt staging "$UNBUILT" >/dev/null 2>&1; then fail "an unbuilt commit deployed without --build-here"; fi
"$DEPLOY" staging "$UNBUILT" --build-here >/dev/null
[ "$(basename "$(readlink "$APP_DIR/current")")" != "" ] && [ ! -f "$APP_DIR/current/BUILD" ] \
  || fail "the --build-here release looks like a CI build"
pass "refused without the flag; built on the box with it"

echo "== status"
"$DEPLOY" staging status

echo
echo "All atomic-deploy checks passed."
