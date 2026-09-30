#!/usr/bin/env bash
#
# Build a deployable release of the commit checked out here, once, and record
# it as a git commit: the source tree plus what the build produced (vendor/,
# public/build/, bootstrap/cache/). CI publishes it as refs/builds/<sha>;
# app-deploy fetches that ref as root over the box's own SSH key and
# unpacks it. See docs/devops.md.
#
#   scripts/build-release.sh                  # prints commit=<build> and tree=<tree>
#   scripts/build-release.sh --push <remote>  # ...and pushes it to refs/builds/<sha>
#
# Why a git ref and not an uploaded tarball: the runner that deploys is an
# unprivileged user, and anything it hands to `sudo app-deploy` could be
# swapped. A ref is fetched by root from GitHub itself, and its tree hash is
# the same on both boxes: that is what "promote the same artifact" means here.
#
# SKIP_FRONTEND=1 skips npm (the end-to-end tests use it).
#
set -euo pipefail

PUSH_REMOTE=
if [ "${1:-}" = --push ]; then PUSH_REMOTE="${2:?--push needs a remote}"; fi

SHA=$(git rev-parse HEAD)
[ -z "$(git status --porcelain --untracked-files=no)" ] \
  || { echo "error: the checkout has local changes; a build must be of a commit exactly" >&2; exit 1; }

log() { printf '\n\033[1m==> %s\033[0m\n' "$*" >&2; }

log "Building $SHA"
COMPOSER_ALLOW_SUPERUSER=1 composer install --no-interaction --prefer-dist \
  --no-progress --no-dev --optimize-autoloader --quiet
if [ "${SKIP_FRONTEND:-}" != 1 ]; then
  npm ci --silent --no-audit --no-fund
  npm run build --silent
fi

# What produced this build, for anyone looking at a release on a box.
cat >BUILD <<INFO
source   $SHA
built    $(date -u +%Y-%m-%dT%H:%M:%SZ)
php      $(php -r 'echo PHP_VERSION;')
node     $(node --version 2>/dev/null || echo "not used")
by       ${GITHUB_SERVER_URL:+$GITHUB_SERVER_URL/$GITHUB_REPOSITORY/actions/runs/$GITHUB_RUN_ID}
INFO

log "Recording the build as a commit"
# A throwaway index, so the checkout's own index is left alone. -f because
# every one of these is (rightly) in .gitignore.
INDEX=$(mktemp)
trap 'rm -f "$INDEX"' EXIT
export GIT_INDEX_FILE="$INDEX"
git read-tree HEAD
git add -f vendor bootstrap/cache BUILD
[ ! -d public/build ] || git add -f public/build
TREE=$(git write-tree)
COMMIT=$(git -c user.name="CI build" -c user.email="build@ci.invalid" \
  commit-tree "$TREE" -p "$SHA" -m "Build of $SHA")
unset GIT_INDEX_FILE
rm -f BUILD

echo "commit=$COMMIT"
echo "tree=$TREE"

if [ -n "$PUSH_REMOTE" ]; then
  log "Publishing refs/builds/$SHA"
  git push --quiet "$PUSH_REMOTE" "$COMMIT:refs/builds/$SHA"
fi
