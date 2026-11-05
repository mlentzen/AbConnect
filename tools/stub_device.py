#!/usr/bin/env python3
"""Creates substitute device profiles so `monkeyc` builds without the SDK Manager.

WHAT THIS IS GOOD FOR: The Connect IQ compiler requires a device profile under
~/.Garmin/ConnectIQ/Devices/. The real profiles are only downloaded by the SDK
Manager after a Garmin login. Without them the code cannot even be compiled.
Every product in app/manifest.xml gets a stub so monkey.jungle device
qualifiers (launcher-icon overlays) resolve; CI still only *builds* fenix7xpro.

WHAT IT IS NOT FOR: The values here are reconstructed, not from Garmin. A green
build proves that the code is syntactically correct, that all API symbols
resolve against the real SDK and that the resources compile. It does *not*
prove that the app fits into the memory limit of the real fenix 7X Pro, that
the layout is right or that it runs on the device. Before every release there
should be a build against the real profile from the SDK Manager, and a test
on the watch.
"""

from __future__ import annotations

import argparse
import json
import re
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
MANIFEST = ROOT / "app" / "manifest.xml"

# Launcher sizes used by monkey.jungle overlays. Anything else stays at 40x40
# like the fenix 7 family base icon.
LAUNCHER_PX: dict[str, int] = {
    "fr165m": 54,
    "fr170m": 54,
    "fr57042mm": 54,
    "venu441mm": 54,
    "vivoactive6": 54,
    "vivoactive5": 56,
    "d2mach1": 60,
    "epix2": 60,
    "epix2pro42mm": 60,
    "epix2pro47mm": 60,
    "epix2pro51mm": 60,
    "fenix843mm": 60,
    "fenix943mm": 60,
    "fenix9pro43mm": 60,
    "fenixe": 60,
    "fr265": 60,
    "fr265s": 60,
    "marq2": 60,
    "marq2aviator": 60,
    "d2mach2": 65,
    "d2mach2pro": 65,
    "fenix847mm": 65,
    "fenix8pro47mm": 65,
    "fenix947mm": 65,
    "fenix9pro47mm": 65,
    "fenix9pro51mm": 65,
    "fr57047mm": 65,
    "fr965": 65,
    "fr970": 65,
    "venu445mm": 65,
    "venu3": 70,
    "venu3s": 70,
}


def base_profile(device_id: str) -> dict:
    px = LAUNCHER_PX.get(device_id, 40)
    return {
        "deviceId": device_id,
        "displayName": f"{device_id} (substitute profile, not from Garmin)",
        "deviceFamily": "fenix7x-20",
        "worldWidePartNumber": "006-B4375-00",
        "orientation": "portrait",
        "bitsPerPixel": 16,
        "resolution": {"width": 280, "height": 280},
        "launcherIcon": {"width": px, "height": px},
        "appTypes": [
            {
                "type": "watchApp",
                "memoryLimit": 1048576,
                "prgLimit": 4194304,
                "fitSessionMemory": 16384,
            },
            {
                "type": "audioContentProvider",
                "memoryLimit": 1048576,
                "prgLimit": 4194304,
                "fitSessionMemory": 0,
            },
            {
                "type": "widget",
                "memoryLimit": 524288,
                "prgLimit": 2097152,
                "fitSessionMemory": 0,
            },
            {
                "type": "background",
                "memoryLimit": 65536,
                "prgLimit": 1048576,
                "fitSessionMemory": 0,
            },
            {
                "type": "glance",
                "memoryLimit": 65536,
                "prgLimit": 1048576,
                "fitSessionMemory": 0,
            },
        ],
        # Do not add supportedAPIAnnotations. An empty list makes the SDK 9
        # compiler throw a NullPointerException while rasterizing SVGs, and
        # monkeyc prints that as "ERROR: null".
        "partNumbers": [
            {
                "number": "006-B4375-00",
                "connectIQVersion": "5.2.0",
                "firmwareVersion": 1400,
                "languages": [
                    {"code": "eng", "fontSet": "vivoactive3"},
                    {"code": "deu", "fontSet": "vivoactive3"},
                ],
            }
        ],
    }


def manifest_products(manifest: Path) -> list[str]:
    text = manifest.read_text(encoding="utf-8")
    return re.findall(r'<iq:product\s+id="([^"]+)"', text)


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "--root",
        type=Path,
        default=Path.home() / ".Garmin" / "ConnectIQ" / "Devices",
        help="directory of the device profiles",
    )
    parser.add_argument(
        "--manifest",
        type=Path,
        default=MANIFEST,
        help="Connect IQ manifest whose products get a stub",
    )
    parser.add_argument(
        "--force",
        action="store_true",
        help="overwrite existing profiles (default: only create missing ones)",
    )
    args = parser.parse_args()

    products = manifest_products(args.manifest)
    if not products:
        raise SystemExit(f"no products found in {args.manifest}")

    written = 0
    skipped = 0
    for device_id in products:
        target = args.root / device_id
        profile_path = target / "compiler.json"
        if profile_path.exists() and not args.force:
            skipped += 1
            continue
        target.mkdir(parents=True, exist_ok=True)
        profile_path.write_text(
            json.dumps(base_profile(device_id), indent=1) + "\n",
            encoding="utf-8",
        )
        written += 1

    print(
        f"Substitute profiles: wrote {written}, left {skipped} existing under {args.root}"
    )
    print(
        "Caution: reconstructed values. Does not replace a build against the real profile."
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
