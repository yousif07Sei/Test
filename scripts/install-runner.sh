#!/usr/bin/env bash
#
# Install and register a self-hosted GitHub Actions runner on this container.
# Run as root, on the box being set up:
#
#   scripts/install-runner.sh staging     <REGISTRATION_TOKEN>
#   scripts/install-runner.sh production  <REGISTRATION_TOKEN>
#
# Get the token from the repo's Settings -> Actions -> Runners -> New
# self-hosted runner. It expires in about an hour, so fetch it just before
# running this. REPO_URL defaults to this repository.
#
set -euo pipefail

ROLE="${1:?usage: install-runner.sh <staging|production> <registration-token>}"
TOKEN="${2:?missing registration token - see the URL in the header of this script}"
REPO_URL="${REPO_URL:-https://github.com/yousif07Sei/Test}"
RUNNER_VERSION="${RUNNER_VERSION:-2.322.0}"
RUNNER_HOME="/home/runner/actions-runner"

case "$ROLE" in
  staging|production) ;;
  *) echo "error: role must be 'staging' or 'production'" >&2; exit 2 ;;
esac

[ "$(id -u)" -eq 0 ] || { echo "error: run as root" >&2; exit 1; }

log() { printf '\n\033[1m==> %s\033[0m\n' "$*"; }

# 1. Unprivileged user. The runner refuses to run as root without an explicit
#    override, and handing CI a root shell by default is not a good trade.
if ! id runner >/dev/null 2>&1; then
  log "Creating user 'runner'"
  useradd -m -s /bin/bash runner
else
  log "User 'runner' already exists"
fi

# 2. Its privileges (root for app-deploy and provision.sh, nothing else) are
#    the sudoers rule that scripts/provision.sh owns, so they are granted by
#    provisioning, not here. Two writers of one file would undo each other.
#    See the last step.

# 3. Runner binaries.
if [ ! -f "$RUNNER_HOME/config.sh" ]; then
  log "Downloading actions-runner v$RUNNER_VERSION"
  mkdir -p "$RUNNER_HOME"
  curl -fsSL -o "$RUNNER_HOME/runner.tar.gz" \
    "https://github.com/actions/runner/releases/download/v${RUNNER_VERSION}/actions-runner-linux-x64-${RUNNER_VERSION}.tar.gz"
  tar xzf "$RUNNER_HOME/runner.tar.gz" -C "$RUNNER_HOME"
  rm -f "$RUNNER_HOME/runner.tar.gz"
  chown -R runner:runner "$RUNNER_HOME"
else
  log "Runner already extracted at $RUNNER_HOME"
fi

log "Installing runner dependencies"
"$RUNNER_HOME/bin/installdependencies.sh"

# 4. Register. Labels must match runs-on in .github/workflows/deploy-*.yml.
log "Registering with $REPO_URL as [self-hosted, app, $ROLE]"
sudo -u runner "$RUNNER_HOME/config.sh" \
  --unattended \
  --url "$REPO_URL" \
  --token "$TOKEN" \
  --name "app-$ROLE" \
  --labels "self-hosted,app,$ROLE" \
  --work _work \
  --replace

# 5. Run it as a service so it survives reboots.
log "Installing and starting the runner service"
cd "$RUNNER_HOME"
./svc.sh install runner
./svc.sh start

log "Done — verify at $REPO_URL/settings/actions/runners"
log "Next: sudo scripts/provision.sh $ROLE --apply (grants the runner its sudo rule)"
systemctl list-units --type=service | grep -i 'actions.runner' || true
