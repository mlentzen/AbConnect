#!/usr/bin/env bash
# Baut AbConnect für die fenix 7X Pro.
#
# Voraussetzungen:
#   CIQ_HOME  Connect-IQ-SDK (Verzeichnis mit bin/monkeyc)
#   CIQ_KEY   Entwicklerschlüssel im PKCS8-DER-Format
#
# Schlüssel erzeugen, falls noch keiner da ist:
#   openssl genrsa -out dev.pem 4096
#   openssl pkcs8 -topk8 -inform PEM -outform DER -in dev.pem -out developer_key -nocrypt
set -euo pipefail

CIQ_HOME="${CIQ_HOME:-/opt/ciq}"
CIQ_KEY="${CIQ_KEY:-$HOME/.ciq/developer_key}"
DEVICE="${DEVICE:-fenix7xpro}"
OUTPUT="${OUTPUT:-build/abconnect.prg}"
# 2 = informative: meldet, was zählt, ohne an den generischen Typparametern
# von Storage und Method hängenzubleiben.
TYPECHECK="${TYPECHECK:-2}"

cd "$(dirname "$0")"
mkdir -p "$(dirname "$OUTPUT")"

"$CIQ_HOME/bin/monkeyc" \
    -f monkey.jungle \
    -d "$DEVICE" \
    -o "$OUTPUT" \
    -y "$CIQ_KEY" \
    -l "$TYPECHECK" \
    "$@"

echo "Gebaut: $OUTPUT"
