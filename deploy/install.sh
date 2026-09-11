#!/usr/bin/env bash
# Installs the quadlets and the rebuild watcher into the user units.
#
# Idempotent: running it repeatedly is the intended way to update the paths
# after a branch switch or a moved checkout.
set -euo pipefail

script_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
repo=$(git -C "$script_dir" rev-parse --show-toplevel)
git_dir=$(git -C "$repo" rev-parse --absolute-git-dir)
branch=$(git -C "$repo" rev-parse --abbrev-ref HEAD)

if [ "$branch" = HEAD ]; then
    echo "Error: detached HEAD — there is no branch for the watcher to observe." >&2
    exit 1
fi

config_home=${XDG_CONFIG_HOME:-$HOME/.config}
quadlet_dir="$config_home/containers/systemd"
unit_dir="$config_home/systemd/user"
mkdir -p "$quadlet_dir" "$unit_dir"

# The two machine-dependent lines are created here, not in the repo: the build
# context is this checkout, and its current branch is what gets watched.
sed "s|^SetWorkingDirectory=.*|SetWorkingDirectory=$repo/proxy|" \
    "$script_dir/abconnect-proxy.build" > "$quadlet_dir/abconnect-proxy.build"
sed "s|^PathChanged=.*|PathChanged=$git_dir/refs/heads/$branch|" \
    "$script_dir/abconnect-proxy-rebuild.path" > "$unit_dir/abconnect-proxy-rebuild.path"

install -m 644 "$script_dir/abconnect-proxy.container" "$quadlet_dir/"
install -m 644 "$script_dir/abconnect-proxy-rebuild.service" "$unit_dir/"

echo "Installed:"
echo "  $quadlet_dir/abconnect-proxy.build          (context: $repo/proxy)"
echo "  $quadlet_dir/abconnect-proxy.container"
echo "  $unit_dir/abconnect-proxy-rebuild.service"
echo "  $unit_dir/abconnect-proxy-rebuild.path      (branch: $branch)"

systemctl --user daemon-reload
systemctl --user enable --now abconnect-proxy-rebuild.path

# The container does not start without secrets — better to say so here than to
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
    exit 0
fi

systemctl --user start abconnect-proxy.service

# Don't maintain the port in two places, read it from the quadlet.
port=$(sed -n 's|^PublishPort=[0-9.]*:\([0-9]*\):.*|\1|p' "$script_dir/abconnect-proxy.container")
echo
echo "Running. Check with: curl -s localhost:${port}/health | python3 -m json.tool"

if ! loginctl show-user "$USER" --property=Linger 2>/dev/null | grep -q 'Linger=yes'; then
    echo
    echo "Note: linger is off — the services end with the last session."
    echo "Persistent operation: loginctl enable-linger $USER"
fi
