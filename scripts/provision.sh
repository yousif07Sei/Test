#!/usr/bin/env bash
#
# Provision the machine the app runs on: everything that is not the app.
#
#   sudo scripts/provision.sh <staging|production>            # plan: show diffs, change nothing
#   sudo scripts/provision.sh <staging|production> --apply    # write, validate, reload
#        scripts/provision.sh <staging|production> --render DIR   # write rendered files under DIR only
#
# It owns the Apache vhost, the Apache modules it needs, the app-queue /
# app-scheduler systemd units, the runner's sudoers rule and the installed
# deploy script. It never writes .env and never deploys: app deploys are
# scripts/app-deploy, and the two are separate jobs on purpose.
#
# Every file is rendered from scripts/provision/templates/ with the values in
# scripts/provision/<env>.conf, and compared with what is on the box. In plan
# mode the differences are printed as a diff and nothing else happens. With
# --apply, each changed file is backed up, and a whole group is validated
# (apache2ctl configtest, systemd-analyze verify, visudo -c) before anything
# is reloaded. A group that fails validation is rolled back from its backups,
# so a bad template never reaches a running service.
#
# Safe to re-run. A box that already matches reports "no changes".
#
set -euo pipefail

ENVIRONMENT="${1:?usage: provision.sh <staging|production> [--apply]}"
MODE="${2:-plan}"
RENDER_DIR="${3:-}"
case "$ENVIRONMENT" in
  staging | production) ;;
  *) echo "error: environment must be 'staging' or 'production'" >&2; exit 2 ;;
esac
case "$MODE" in
  plan | --apply) ;;
  --render) [ -n "$RENDER_DIR" ] || { echo "error: --render needs a directory" >&2; exit 2; } ;;
  *) echo "error: second argument must be --apply, --render DIR, or nothing for a plan" >&2; exit 2 ;;
esac

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONF="$HERE/provision/$ENVIRONMENT.conf"
TEMPLATES="$HERE/provision/templates"
[ -f "$CONF" ] || { echo "error: no config at $CONF" >&2; exit 2; }
# shellcheck source=/dev/null
. "$CONF"

# --render only writes into its own directory, so it needs neither root nor
# the right machine: it is how templates are reviewed off the box.
if [ "$MODE" != --render ]; then
[ "$(id -u)" -eq 0 ] || { echo "error: run as root (the plan reads sudoers)" >&2; exit 1; }

if [ "$(hostname)" != "$EXPECTED_HOSTNAME" ]; then
  echo "error: $CONF is for '$EXPECTED_HOSTNAME', but this machine is '$(hostname)'." >&2
  echo "       Refusing to provision the wrong box." >&2
  exit 2
fi
fi

STAMP=$(date +%Y%m%d%H%M%S)
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

log() { printf '\n\033[1m==> %s\033[0m\n' "$*"; }
note() { printf '    %s\n' "$*"; }
warn() { printf '\n\033[1;33m!!> %s\033[0m\n' "$*" >&2; }
die() { printf '\n\033[1;31mxx> %s\033[0m\n' "$*" >&2; exit 1; }

# Where the app is served from: `current`, the live release.
APP_ROOT="$APP_DIR/current"

# ---------------------------------------------------------------------------
# Rendering. Placeholders are @NAME@, replaced from a fixed list, so Apache's
# own ${APACHE_LOG_DIR} and systemd's %i pass through untouched. No envsubst:
# it is not on every minimal image.
# ---------------------------------------------------------------------------
VARS=(ENVIRONMENT ENV_LABEL APP_DIR APP_ROOT WEB_USER RUNNER_USER DOMAIN
  SERVER_ALIAS_DIRECTIVE HSTS_DIRECTIVE LOG_NAME)

render() {
  local src="$TEMPLATES/$1" out="$2" v
  # repo:<path> is a file installed as it is, not a template: a script such as
  # app-deploy, whose own "$@" and ${arr[@]} must not be touched.
  if [[ "$1" == repo:* ]]; then
    src="$HERE/${1#repo:}"
    [ -f "$src" ] || die "missing $src"
    cp "$src" "$out"
    return
  fi
  [ -f "$src" ] || die "missing template $src"
  cp "$src" "$out"
  for v in "${VARS[@]}"; do
    # An optional directive left empty removes its whole line, rather than
    # leaving a blank one where it would have been.
    if [ -z "${!v}" ]; then
      sed -i "/^[[:space:]]*@$v@[[:space:]]*\$/d" "$out"
    fi
    # | as the delimiter: values are paths and domains, never contain it.
    sed -i "s|@$v@|${!v}|g" "$out"
  done
  if grep -q '@[A-Z_]*@' "$out"; then
    die "unreplaced placeholder in $1: $(grep -o '@[A-Z_]*@' "$out" | sort -u | tr '\n' ' ')"
  fi
}

# ---------------------------------------------------------------------------
# One managed file: render, compare, and in apply mode stage it for writing.
# Changed files in a group are only committed together, after validation.
#   manage <group> <template> <dest> <mode>
# ---------------------------------------------------------------------------
declare -A GROUP_CHANGED=()
CHANGES=0
STAGED=()   # "group|dest|rendered|mode"

manage() {
  local group="$1" tpl="$2" dest="$3" mode="$4"
  # Rendered under its real basename: systemd-analyze verify needs the
  # .service/.timer suffix to know what it is looking at.
  local new="$WORK/$group/$(basename "$dest")"
  mkdir -p "$WORK/$group"
  render "$tpl" "$new"

  if [ "$MODE" = --render ]; then
    install -D -m 644 "$new" "$RENDER_DIR$dest"
    note "rendered   $RENDER_DIR$dest"
    return
  fi

  if [ -f "$dest" ] && cmp -s "$dest" "$new"; then
    note "unchanged  $dest"
    return
  fi

  CHANGES=$((CHANGES + 1))
  GROUP_CHANGED[$group]=1
  if [ -f "$dest" ]; then
    note "CHANGE     $dest"
    diff -u --label "$dest (on the box)" --label "$dest (provisioned)" \
      "$dest" "$new" | sed 's/^/      /' || true
  else
    note "NEW        $dest"
    sed 's/^/      + /' "$new"
  fi
  STAGED+=("$group|$dest|$new|$mode")
}

# Write every staged file of a group, keeping a backup of each original.
commit_group() {
  local group="$1" entry g dest new mode
  for entry in "${STAGED[@]}"; do
    IFS='|' read -r g dest new mode <<<"$entry"
    [ "$g" = "$group" ] || continue
    if [ -f "$dest" ]; then
      cp -p "$dest" "$dest.bak-$STAMP"
    else
      : >"$WORK/$group/.created-$(basename "$dest")"
    fi
    install -D -m "$mode" "$new" "$dest"
    note "wrote $dest"
  done
}

# Put a group back exactly as it was: restore backups, remove new files.
rollback_group() {
  local group="$1" entry g dest new mode
  for entry in "${STAGED[@]}"; do
    IFS='|' read -r g dest new mode <<<"$entry"
    [ "$g" = "$group" ] || continue
    if [ -f "$dest.bak-$STAMP" ]; then
      mv -f "$dest.bak-$STAMP" "$dest"
    elif [ -f "$WORK/$group/.created-$(basename "$dest")" ]; then
      rm -f "$dest"
    fi
    note "restored $dest"
  done
}

group_changed() { [ -n "${GROUP_CHANGED[$1]:-}" ]; }

staged_file_changed() {
  local entry g dest new mode
  for entry in "${STAGED[@]}"; do
    IFS='|' read -r g dest new mode <<<"$entry"
    [ "$dest" = "$1" ] && return 0
  done
  return 1
}

# ---------------------------------------------------------------------------
# Every file provisioning owns: group|template|destination|mode. The one list
# that --render, the plan and --apply all walk, so CI renders exactly what a
# box would get.
# ---------------------------------------------------------------------------
MANAGED=(
  "apache|vhost.conf|/etc/apache2/sites-available/$SITE_NAME.conf|644"
  "systemd|app-queue.service|/etc/systemd/system/app-queue.service|644"
  "systemd|app-scheduler.service|/etc/systemd/system/app-scheduler.service|644"
  "systemd|app-scheduler.timer|/etc/systemd/system/app-scheduler.timer|644"
  "sudoers|sudoers|/etc/sudoers.d/app-deploy|440"
  "bin|repo:app-deploy|/usr/local/sbin/app-deploy|755"
)
UNITS=(app-queue.service app-scheduler.service app-scheduler.timer)

manage_group() {
  local entry g tpl dest mode
  for entry in "${MANAGED[@]}"; do
    IFS='|' read -r g tpl dest mode <<<"$entry"
    [ "$g" = "$1" ] && manage "$g" "$tpl" "$dest" "$mode"
  done
  return 0
}

log "Provisioning $ENVIRONMENT ($MODE)"
note "domain    $DOMAIN"
note "app root  $APP_ROOT"

# ===========================================================================
# 1. Apache modules the vhost needs
# ===========================================================================
MISSING_MODS=()
if [ "$MODE" = --render ]; then
  for group in apache systemd sudoers bin; do manage_group "$group"; done
  log "Rendered $ENVIRONMENT into $RENDER_DIR"
  exit 0
fi

log "Apache modules"
MODS=(rewrite)
# mod_headers only where the vhost sends HSTS.
[ -z "$HSTS_DIRECTIVE" ] || MODS+=(headers)
for mod in "${MODS[@]}"; do
  if a2query -q -m "$mod"; then
    note "enabled    $mod"
  else
    note "MISSING    $mod"
    MISSING_MODS+=("$mod")
  fi
done

# ===========================================================================
# 2. Apache site
# ===========================================================================
log "Apache site"
manage_group apache
if [ -L "/etc/apache2/sites-enabled/$SITE_NAME.conf" ]; then
  note "enabled    site $SITE_NAME"
else
  note "NOT ENABLED site $SITE_NAME"
  GROUP_CHANGED[apache]=1
  CHANGES=$((CHANGES + 1))
fi

# ===========================================================================
# 3. systemd units
# ===========================================================================
log "systemd units"
manage_group systemd

# ===========================================================================
# 4. The runner's sudoers rule
# ===========================================================================
log "sudoers"
manage_group sudoers

# ===========================================================================
# 5. The deploy script sudo runs. Installed outside the tree it deploys, so
#    what root executes changes only when a box is provisioned, never as a
#    side effect of the deploy itself.
# ===========================================================================
log "Deploy script"
manage_group bin

# ===========================================================================
# Plan ends here
# ===========================================================================
if [ "$MODE" != --apply ]; then
  if [ "$CHANGES" -eq 0 ] && [ "${#MISSING_MODS[@]}" -eq 0 ]; then
    log "No changes: $ENVIRONMENT already matches"
  else
    log "Plan: $CHANGES file change(s), ${#MISSING_MODS[@]} module(s) to enable"
    note "Nothing was changed. Re-run with --apply to make these changes."
  fi
  exit 0
fi

# ===========================================================================
# Apply. Order matters: sudoers and systemd validate the new file before it
# is installed; Apache can only be validated as a whole config, so its files
# are installed first and rolled back if configtest refuses them.
# ===========================================================================
# The deploy script before the sudoers rule that names it, so the rule never
# points at a file that is not there yet.
if group_changed bin; then
  log "Applying the deploy script"
  bash -n "$WORK/bin/app-deploy" || die "app-deploy does not parse; nothing was written"
  commit_group bin
fi

if group_changed sudoers; then
  log "Applying sudoers"
  visudo -c -q -f "$WORK/sudoers/app-deploy" \
    || die "the rendered sudoers file does not parse; nothing was written"
  commit_group sudoers
fi

if group_changed systemd; then
  log "Applying systemd units"
  # verify also loads the units ours depend on, and may warn about them. Show
  # only what is about our own files, so a real warning is not buried under
  # a familiar one. The exit status still decides.
  if ! VERIFY_OUT=$(systemd-analyze verify "$WORK"/systemd/*.service "$WORK"/systemd/*.timer 2>&1); then
    printf '%s\n' "$VERIFY_OUT" | sed 's/^/      /'
    die "systemd-analyze refused the rendered units; nothing was written"
  fi
  printf '%s\n' "$VERIFY_OUT" | grep -F -e "$WORK/" -e app- | sed 's/^/      /' || true
  commit_group systemd
  systemctl daemon-reload
  systemctl enable --quiet app-queue.service app-scheduler.timer
  # Restart only what changed, so a change to the scheduler does not
  # interrupt a queue worker mid-job.
  for unit in "${UNITS[@]}"; do
    staged_file_changed "/etc/systemd/system/$unit" || continue
    case "$unit" in
      # A oneshot the timer fires every minute; nothing to restart.
      app-scheduler.service) continue ;;
    esac
    systemctl restart "$unit"
    systemctl is-active --quiet "$unit" || die "$unit did not come up: systemctl status $unit"
    note "restarted $unit"
  done
fi

if [ "${#MISSING_MODS[@]}" -gt 0 ] || group_changed apache; then
  log "Applying Apache"
  [ "${#MISSING_MODS[@]}" -eq 0 ] || a2enmod -q "${MISSING_MODS[@]}"
  commit_group apache
  a2ensite -q "$SITE_NAME"
  if ! apache2ctl configtest; then
    rollback_group apache
    die "apache2ctl configtest refused the new config; it was rolled back and Apache was not reloaded"
  fi
  systemctl reload apache2
  note "reloaded apache2"
fi

log "Provisioned $ENVIRONMENT"
