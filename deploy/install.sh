#!/usr/bin/env bash
# Installs the proxy quadlet and starts it from the published image.
#
# Running it again reinstalls the quadlet and restarts the service.
# It does not enable podman-auto-update.timer; that stays the operator's choice.
set -euo pipefail

script_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
config_home=${XDG_CONFIG_HOME:-$HOME/.config}
quadlet_dir="$config_home/containers/systemd"
mkdir -p "$quadlet_dir"

image=ghcr.io/mlentzen/abconnect-proxy:latest

# Printed only while the timer is present and not enabled, so opting in once
# silences it. The quadlet's AutoUpdate= label is what the commands act on.
update_hint() {
    if systemctl --user cat podman-auto-update.timer >/dev/null 2>&1 \
        && ! systemctl --user is-enabled --quiet podman-auto-update.timer; then
        echo
        echo "Note: image updates are off."
        echo "Once:  systemctl --user start podman-auto-update.service"
        echo "Daily: systemctl --user enable --now podman-auto-update.timer"
    fi
}

install -m 644 "$script_dir/abconnect-proxy.container" "$quadlet_dir/"

systemctl --user daemon-reload

echo "Installed:"
echo "  $quadlet_dir/abconnect-proxy.container"
echo "  image: $image"

# The container does not start without secrets. Better to say so here than to
# make someone dig it out of a journal entry.
missing=()
for secret in abconnect-users; do
    podman secret exists "$secret" || missing+=("$secret")
done

if [ ${#missing[@]} -gt 0 ]; then
    echo
    echo "Still missing the secrets: ${missing[*]}"
    echo "Create them (see deploy/README.md), then:"
    echo "  systemctl --user start abconnect-proxy"
    update_hint
    exit 0
fi

echo
echo "Pulling $image"
if ! podman pull "$image"; then
    echo "The image is not available yet. A push of proxy/ to main publishes it." >&2
    echo "The service was not restarted." >&2
    exit 1
fi

systemctl --user enable abconnect-proxy.service
systemctl --user restart abconnect-proxy.service

# Don't maintain the port in two places, read it from the quadlet.
port=$(sed -n 's|^PublishPort=[0-9.]*:\([0-9]*\):.*|\1|p' "$script_dir/abconnect-proxy.container")
echo
echo "Running. Check with: curl -s localhost:${port}/health | python3 -m json.tool"

update_hint

if ! loginctl show-user "$USER" --property=Linger 2>/dev/null | grep -q 'Linger=yes'; then
    echo
    echo "Note: linger is off. The services end with the last session."
    echo "Persistent operation: loginctl enable-linger $USER"
fi
