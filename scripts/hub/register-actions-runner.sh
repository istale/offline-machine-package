#!/usr/bin/env bash
# scripts/hub/register-actions-runner.sh
# Register a Gitea Actions runner on the hub (rootless podman + systemd --user
# unit, same pattern as Nexus). Image already shipped via images-bundle as
# docker.io/gitea/act_runner:latest.
#
# Prereqs:
#   1. Gitea is reachable at $GITEA_BASE
#   2. You generated a runner registration token in Gitea:
#      Site Admin → Actions → Runners → Create new Runner → copy token
set -euo pipefail

# ============ fill in ============
GITEA_BASE="${GITEA_BASE:?export GITEA_BASE (e.g. http://gitea.internal:3000)}"
RUNNER_TOKEN="${RUNNER_TOKEN:?export RUNNER_TOKEN (from Gitea Admin → Runners)}"
RUNNER_NAME="${RUNNER_NAME:-hub-runner-1}"
RUNNER_LABELS="${RUNNER_LABELS:-self-hosted,linux,x86_64,rhel-8.10}"
RUNNER_DATA="${RUNNER_DATA:-/srv/act-runner-data}"
RUNNER_IMAGE="${RUNNER_IMAGE:-docker.io/gitea/act_runner:latest}"
# =================================

[[ "$(id -un)" == "webadmin" ]] || { echo "run as webadmin"; exit 1; }

mkdir -p "$RUNNER_DATA"
podman unshare chown -R 1000:1000 "$RUNNER_DATA"

# Register once (writes .runner config into $RUNNER_DATA)
if [[ ! -f "$RUNNER_DATA/.runner" ]]; then
  echo "[runner] registering with $GITEA_BASE"
  podman run --rm \
    -v "$RUNNER_DATA":/data:Z \
    "$RUNNER_IMAGE" \
    act_runner register --no-interactive \
      --instance "$GITEA_BASE" \
      --token "$RUNNER_TOKEN" \
      --name "$RUNNER_NAME" \
      --labels "$RUNNER_LABELS"
else
  echo "[runner] already registered (found $RUNNER_DATA/.runner)"
fi

# systemd --user unit
UNIT="$HOME/.config/systemd/user/act-runner.service"
mkdir -p "$(dirname "$UNIT")"
cat > "$UNIT" <<EOF
[Unit]
Description=Gitea Actions runner (act_runner)
After=network-online.target
Wants=network-online.target

[Service]
Restart=on-failure
RestartSec=10
ExecStartPre=-/usr/bin/podman rm -f act-runner
ExecStart=/usr/bin/podman run --name act-runner --rm \\
  -v $RUNNER_DATA:/data:Z \\
  -v /run/user/$(id -u)/podman/podman.sock:/var/run/docker.sock \\
  $RUNNER_IMAGE
ExecStop=/usr/bin/podman stop -t 10 act-runner

[Install]
WantedBy=default.target
EOF

# expose podman socket so the runner can build/push images
systemctl --user enable --now podman.socket || true

loginctl enable-linger "$(id -un)" 2>/dev/null || sudo loginctl enable-linger "$(id -un)"
systemctl --user daemon-reload
systemctl --user enable --now act-runner

echo
echo "[runner] ✅ registered + started"
echo "  Verify in Gitea: Site Admin → Actions → Runners (should see '$RUNNER_NAME' online)"
echo "  Logs:           journalctl --user -u act-runner -f"
