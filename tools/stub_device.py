#!/usr/bin/env python3
"""Erzeugt ein Ersatz-Geräteprofil, damit `monkeyc` ohne SDK-Manager baut.

WOFÜR DAS GUT IST: Der Connect-IQ-Compiler verlangt ein Geräteprofil unter
~/.Garmin/ConnectIQ/Devices/. Die echten Profile lädt nur der SDK-Manager nach
einem Garmin-Login. Ohne sie lässt sich der Code nicht einmal übersetzen.

WOFÜR NICHT: Die Werte hier sind nachgebaut, nicht von Garmin. Ein grüner Build
belegt, dass der Code syntaktisch stimmt, dass alle API-Symbole gegen das echte
SDK auflösen und dass die Ressourcen übersetzen. Er belegt *nicht*, dass die App
in das Speicherlimit der echten fenix 7X Pro passt, dass das Layout stimmt oder
dass sie auf dem Gerät läuft. Vor jedem Release gehört ein Build gegen das echte
Profil aus dem SDK-Manager — und ein Test auf der Uhr.
"""

from __future__ import annotations

import argparse
import json
from pathlib import Path

PROFILE = {
    "deviceId": "fenix7xpro",
    "displayName": "fenix 7X Pro (Ersatzprofil, nicht von Garmin)",
    "deviceFamily": "fenix7x-20",
    "worldWidePartNumber": "006-B4375-00",
    "orientation": "portrait",
    "bitsPerPixel": 16,
    "resolution": {"width": 280, "height": 280},
    "launcherIcon": {"width": 40, "height": 40},
    "appTypes": [
        {"type": "watchApp", "memoryLimit": 1048576, "prgLimit": 4194304, "fitSessionMemory": 16384},
        {"type": "audioContentProvider", "memoryLimit": 1048576, "prgLimit": 4194304, "fitSessionMemory": 0},
        {"type": "widget", "memoryLimit": 524288, "prgLimit": 2097152, "fitSessionMemory": 0},
        {"type": "background", "memoryLimit": 65536, "prgLimit": 1048576, "fitSessionMemory": 0},
        {"type": "glance", "memoryLimit": 65536, "prgLimit": 1048576, "fitSessionMemory": 0},
    ],
    "partNumbers": [
        {
            "number": "006-B4375-00",
            "connectIQVersion": "5.2.0",
            "firmwareVersion": 1400,
            "languages": [
                {"code": "eng", "fontSet": "vivoactive3"},
                {"code": "deu", "fontSet": "vivoactive3"},
            ],
            "supportedAPIAnnotations": [],
        }
    ],
}


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "--root",
        type=Path,
        default=Path.home() / ".Garmin" / "ConnectIQ" / "Devices",
        help="Verzeichnis der Geräteprofile",
    )
    args = parser.parse_args()

    target = args.root / PROFILE["deviceId"]
    target.mkdir(parents=True, exist_ok=True)
    (target / "compiler.json").write_text(json.dumps(PROFILE, indent=1), encoding="utf-8")
    print(f"Ersatzprofil geschrieben: {target / 'compiler.json'}")
    print("Achtung: nachgebaute Werte. Ersetzt keinen Build gegen das echte Profil.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
