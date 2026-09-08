#!/usr/bin/env bash
# Installiert die Quadlets und den Rebuild-Watcher in die User-Units.
#
# Idempotent: mehrfaches Ausführen ist der vorgesehene Weg, um nach einem
# Branch-Wechsel oder einem verschobenen Checkout die Pfade nachzuziehen.
set -euo pipefail

script_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
repo=$(git -C "$script_dir" rev-parse --show-toplevel)
git_dir=$(git -C "$repo" rev-parse --absolute-git-dir)
branch=$(git -C "$repo" rev-parse --abbrev-ref HEAD)

if [ "$branch" = HEAD ]; then
    echo "Fehler: detached HEAD — es gibt keinen Branch, den der Watcher beobachten könnte." >&2
    exit 1
fi

config_home=${XDG_CONFIG_HOME:-$HOME/.config}
quadlet_dir="$config_home/containers/systemd"
unit_dir="$config_home/systemd/user"
mkdir -p "$quadlet_dir" "$unit_dir"

# Die beiden maschinenabhängigen Zeilen entstehen hier, nicht im Repo: der
# Build-Kontext ist dieser Checkout, beobachtet wird dessen aktueller Branch.
sed "s|^SetWorkingDirectory=.*|SetWorkingDirectory=$repo/proxy|" \
    "$script_dir/abconnect-proxy.build" > "$quadlet_dir/abconnect-proxy.build"
sed "s|^PathChanged=.*|PathChanged=$git_dir/refs/heads/$branch|" \
    "$script_dir/abconnect-proxy-rebuild.path" > "$unit_dir/abconnect-proxy-rebuild.path"

install -m 644 "$script_dir/abconnect-proxy.container" "$quadlet_dir/"
install -m 644 "$script_dir/abconnect-proxy-rebuild.service" "$unit_dir/"

echo "Installiert:"
echo "  $quadlet_dir/abconnect-proxy.build          (Kontext: $repo/proxy)"
echo "  $quadlet_dir/abconnect-proxy.container"
echo "  $unit_dir/abconnect-proxy-rebuild.service"
echo "  $unit_dir/abconnect-proxy-rebuild.path      (Branch: $branch)"

systemctl --user daemon-reload
systemctl --user enable --now abconnect-proxy-rebuild.path

# Ohne Secrets startet der Container nicht — das lieber hier sagen als es aus
# einem Journal-Eintrag herauslesen zu lassen.
missing=()
for secret in abs-api-key abconnect-token; do
    podman secret exists "$secret" || missing+=("$secret")
done

if [ ${#missing[@]} -gt 0 ]; then
    echo
    echo "Es fehlen noch die Secrets: ${missing[*]}"
    echo "Anlegen (siehe deploy/README.md), danach:"
    echo "  systemctl --user start abconnect-proxy"
    exit 0
fi

systemctl --user start abconnect-proxy.service

# Den Port nicht doppelt pflegen, sondern aus dem Quadlet lesen.
port=$(sed -n 's|^PublishPort=[0-9.]*:\([0-9]*\):.*|\1|p' "$script_dir/abconnect-proxy.container")
echo
echo "Läuft. Prüfen mit: curl -s localhost:${port}/healthz | python3 -m json.tool"

if ! loginctl show-user "$USER" --property=Linger 2>/dev/null | grep -q 'Linger=yes'; then
    echo
    echo "Hinweis: Linger ist aus — die Dienste enden mit der letzten Sitzung."
    echo "Dauerbetrieb: loginctl enable-linger $USER"
fi
