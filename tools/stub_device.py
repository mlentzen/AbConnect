#!/usr/bin/env python3
"""Creates a substitute device profile so `monkeyc` builds without the SDK Manager.

WHAT THIS IS GOOD FOR: The Connect IQ compiler requires a device profile under
~/.Garmin/ConnectIQ/Devices/. The real profiles are only downloaded by the SDK
Manager after a Garmin login. Without them the code cannot even be compiled.

WHAT IT IS NOT FOR: The values here are reconstructed, not from Garmin. A green
build proves that the code is syntactically correct, that all API symbols
resolve against the real SDK and that the resources compile. It does *not*
prove that the app fits into the memory limit of the real fenix 7X Pro, that
the layout is right or that it runs on the device. Before every release there
should be a build against the real profile from the SDK Manager — and a test
on the watch.
"""

from __future__ import annotations

import argparse
import json
from pathlib import Path

PROFILE = {
    "deviceId": "fenix7xpro",
    "displayName": "fenix 7X Pro (substitute profile, not from Garmin)",
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
        help="directory of the device profiles",
    )
    args = parser.parse_args()

    target = args.root / PROFILE["deviceId"]
    target.mkdir(parents=True, exist_ok=True)
    (target / "compiler.json").write_text(json.dumps(PROFILE, indent=1), encoding="utf-8")
    print(f"Substitute profile written: {target / 'compiler.json'}")
    print("Caution: reconstructed values. Does not replace a build against the real profile.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
