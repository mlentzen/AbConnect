#!/usr/bin/env bash
# Baut AbConnect für die fenix 7X Pro.
#
# Voraussetzungen:
#   CIQ_HOME  Connect-IQ-SDK (Verzeichnis mit bin/monkeyc)
#   CIQ_KEY   Entwicklerschlüssel im PKCS8-DER-Format
#
# Aus der .env übernommen (optional, beides wird in den Build eingebacken):
#   PROXY_URL    Basis-URL von abconnect-proxy
#   PROXY_TOKEN  zugehöriges ABCONNECT_TOKEN
#
# Schlüssel erzeugen, falls noch keiner da ist:
#   openssl genrsa -out dev.pem 4096
#   openssl pkcs8 -topk8 -inform PEM -outform DER -in dev.pem -out developer_key -nocrypt
set -euo pipefail

cd "$(dirname "$0")"

# .env laden (optional, wird nicht eingecheckt)
if [[ -f .env ]]; then
    set -a          # alles, was jetzt zugewiesen wird, wird exportiert
    source ./.env
    set +a
fi

CIQ_HOME="${CIQ_HOME:-/opt/ciq}"
CIQ_KEY="${CIQ_KEY:-$HOME/.ciq/developer_key}"
DEVICE="${DEVICE:-fenix7xpro}"
OUTPUT="${OUTPUT:-build/abconnect.prg}"
# 2 = informative: meldet, was zählt, ohne an den generischen Typparametern
# von Storage und Method hängenzubleiben.
TYPECHECK="${TYPECHECK:-2}"

mkdir -p "$(dirname "$OUTPUT")"

# Proxy-Vorgaben in eine generierte Quelldatei schreiben.
#
# Connect IQ kennt keine Compiler-Defines und die Werte aus der .env erreichen
# den Übersetzer nicht von allein — ohne diesen Schritt startet die App mit
# leeren Einstellungen. Die App liest sie als Vorgabe, solange in den
# Telefon-Einstellungen nichts anderes steht. Die Datei wird bei jedem Build neu
# erzeugt und nicht eingecheckt, weil sie das Token enthält.
GENERATED="source/BuildDefaults.mc"

# In Monkey-C-String-Literale dürfen Backslash und Anführungszeichen nur
# maskiert; Zeilenumbrüche gar nicht.
escape_literal() {
    printf '%s' "${1//$'\n'/}" | sed -e 's/\\/\\\\/g' -e 's/"/\\"/g'
}

cat > "$GENERATED" <<EOF
// Von build.sh erzeugt — nicht bearbeiten, nicht einchecken.
import Toybox.Lang;

//! Beim Bauen eingebackene Vorgaben für die Proxy-Einstellungen.
//!
//! Leer, wenn beim Bauen keine .env vorlag; dann bleibt es bei den
//! Einstellungen aus der Telefon-App.
module BuildDefaults {
    const PROXY_URL = "$(escape_literal "${PROXY_URL:-}")";
    const PROXY_TOKEN = "$(escape_literal "${PROXY_TOKEN:-}")";
}
EOF

if [[ -z "${PROXY_URL:-}" || -z "${PROXY_TOKEN:-}" ]]; then
    echo "Warnung: PROXY_URL/PROXY_TOKEN nicht gesetzt — Build ohne Vorgaben." >&2
fi

"$CIQ_HOME/bin/monkeyc" \
    -f monkey.jungle \
    -d "$DEVICE" \
    -o "$OUTPUT" \
    -y "$CIQ_KEY" \
    -l "$TYPECHECK" \
    "$@"
echo "Gebaut: $OUTPUT"
