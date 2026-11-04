#!/usr/bin/env bash
# Copies the build and its log file to a watch mounted over MTP.
#
# Set WATCH_MTP in app/.env to the watch's gio URI, e.g.
#   WATCH_MTP="mtp://<vendor>_<product>_<serial>"
# (`gio mount -l` lists it while the watch is plugged in).
set -euo pipefail
cd "$(dirname "$0")"

if [[ -f .env ]]; then
    set -a
    source ./.env
    set +a
fi
: "${WATCH_MTP:?Set WATCH_MTP in app/.env (see the comment at the top of this script)}"

target="$WATCH_MTP/Internal%20Storage/GARMIN/Apps"
gio copy build/abconnect.prg "$target"
gio copy build/abconnect.TXT "$target/LOGS"
