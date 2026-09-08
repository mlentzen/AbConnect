#!/usr/bin/env python3
"""Prüft die Segmente eines Buchs auf dem eigenen Rechner.

Auf der Uhr ist nicht zu unterscheiden, ob eine Datei kaputt ist oder das
Gerät sie nur nicht mag. Hier lässt sich beides trennen:

* ffprobe liest die Kopfdaten — Codec, Profil, Abtastrate, Kanäle, Dauer.
* Ein vollständiger Decodierlauf (``-f null``) findet Abbrüche im Datenstrom,
  die in den Kopfdaten nicht auffallen.
* volumedetect beantwortet die Frage, die ffprobe nicht stellt: ist da
  überhaupt Ton drin, oder sind es 15 Minuten Stille?

Aufruf::

    tools/check_segments.py                 # Playlist zeigen
    tools/check_segments.py <buch-id>       # erste 3 Segmente prüfen
    tools/check_segments.py <buch-id> --all
    tools/check_segments.py <buch-id> --keep /tmp/seg   # Dateien behalten

PROXY_URL und PROXY_TOKEN kommen aus der Umgebung oder aus app/.env.
"""

from __future__ import annotations

import argparse
import json
import os
import re
import shutil
import subprocess
import sys
import tempfile
import urllib.error
import urllib.request
from pathlib import Path

ENV_FILE = Path(__file__).resolve().parent.parent / "app" / ".env"

# Was die Uhr erwiesenermaßen frisst, ist nicht dokumentiert. Diese Werte sind
# die aus der Praxis üblichen für Garmin-Musikuhren; alles andere wird nur
# markiert, nicht als Fehler gewertet.
EXPECTED_RATES = {44100, 48000}


def load_env() -> tuple[str, str]:
    """Umgebung schlägt .env — sonst wie build.sh."""
    url, token = os.environ.get("PROXY_URL", ""), os.environ.get("PROXY_TOKEN", "")
    if (not url or not token) and ENV_FILE.exists():
        for line in ENV_FILE.read_text(encoding="utf-8").splitlines():
            match = re.match(r'\s*(?:export\s+)?(\w+)\s*=\s*(.*?)\s*$', line)
            if not match:
                continue
            key, value = match.group(1), match.group(2).strip('"\'')
            if key == "PROXY_URL" and not url:
                url = value
            elif key == "PROXY_TOKEN" and not token:
                token = value
    if not url or not token:
        sys.exit("PROXY_URL/PROXY_TOKEN fehlen (Umgebung oder app/.env).")
    return url.rstrip("/"), token


def get(url: str, token: str, path: str) -> bytes:
    request = urllib.request.Request(url + path, headers={"Authorization": f"Bearer {token}"})
    try:
        with urllib.request.urlopen(request, timeout=120) as response:
            return response.read()
    except urllib.error.HTTPError as error:
        sys.exit(f"HTTP {error.code} für {path}: {error.read()[:200].decode('utf-8', 'replace')}")


def ffprobe(path: Path) -> dict:
    out = subprocess.run(
        ["ffprobe", "-v", "error", "-show_streams", "-show_format", "-print_format", "json", str(path)],
        capture_output=True, text=True,
    )
    if out.returncode != 0:
        return {}
    data = json.loads(out.stdout)
    stream = next((s for s in data.get("streams", []) if s.get("codec_type") == "audio"), {})
    return {
        "codec": stream.get("codec_name", "?"),
        "profile": stream.get("profile", "?"),
        "rate": int(stream.get("sample_rate", 0) or 0),
        "channels": int(stream.get("channels", 0) or 0),
        "duration": float(data.get("format", {}).get("duration", 0) or 0),
        "start_time": float(stream.get("start_time", 0) or 0),
    }


def decode_check(path: Path) -> str:
    """Vollständig decodieren. Leerer String heißt: sauber durchgelaufen."""
    out = subprocess.run(
        ["ffmpeg", "-v", "error", "-i", str(path), "-f", "null", "-"],
        capture_output=True, text=True,
    )
    return " ".join(out.stderr.split())[:120]


def loudness(path: Path) -> tuple[float, float]:
    """(mittlere, höchste) Lautstärke in dB. -91 dB heißt: Stille."""
    out = subprocess.run(
        ["ffmpeg", "-v", "info", "-i", str(path), "-af", "volumedetect", "-f", "null", "-"],
        capture_output=True, text=True,
    )
    mean = re.search(r"mean_volume:\s*(-?[\d.]+) dB", out.stderr)
    peak = re.search(r"max_volume:\s*(-?[\d.]+) dB", out.stderr)
    return (float(mean.group(1)) if mean else 0.0, float(peak.group(1)) if peak else 0.0)


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("book", nargs="?", help="Buch-ID; ohne sie wird die Playlist gezeigt")
    parser.add_argument("--all", action="store_true", help="alle Segmente statt der ersten drei")
    parser.add_argument("--limit", type=int, default=3)
    parser.add_argument("--keep", metavar="DIR", help="Dateien dort behalten statt sie zu verwerfen")
    args = parser.parse_args()

    for tool in ("ffprobe", "ffmpeg"):
        if shutil.which(tool) is None:
            sys.exit(f"{tool} nicht gefunden.")

    url, token = load_env()

    if not args.book:
        data = json.loads(get(url, token, "/v1/playlist"))
        print(f"Playlist {data.get('playlist')!r} — {len(data.get('books', []))} Bücher\n")
        for book in data.get("books", []):
            print(f"  {book['id']}  {book.get('status','?'):<10}  {book.get('title','')}")
        return 0

    listing = json.loads(get(url, token, f"/v1/books/{args.book}/segments"))
    segments = listing["segments"]
    chosen = segments if args.all else segments[: args.limit]
    print(f"{listing.get('title')} — {len(segments)} Segmente, geprüft: {len(chosen)}\n")

    target = Path(args.keep) if args.keep else Path(tempfile.mkdtemp(prefix="abconnect-"))
    target.mkdir(parents=True, exist_ok=True)

    header = f"{'Seg':>3}  {'Codec':<12} {'Rate':>6} {'Kan':>3}  {'Dauer':>8} {'Δ':>6}  {'Bytes':>10} {'Ø dB':>7} {'Max dB':>7}  Decodierlauf"
    print(header)
    print("-" * len(header))

    problems: list[str] = []
    for entry in chosen:
        path = target / f"{entry['index']:04d}.m4a"
        path.write_bytes(get(url, token, entry["url"]))

        info = ffprobe(path)
        error = decode_check(path)
        mean, peak = loudness(path)
        drift = info.get("duration", 0) - float(entry["duration"])
        size_ok = path.stat().st_size == entry["bytes"]

        flags = []
        if info.get("rate") not in EXPECTED_RATES:
            flags.append(f"Abtastrate {info.get('rate')} unüblich")
        if not size_ok:
            flags.append(f"Größe {path.stat().st_size} != Manifest {entry['bytes']}")
        if abs(drift) > 1.0:
            flags.append(f"Dauer weicht {drift:+.2f}s ab")
        if peak < -60:
            flags.append("praktisch stumm")
        if error:
            flags.append(f"Decoder: {error}")
        if info.get("start_time", 0) > 0.01:
            flags.append(f"start_time {info['start_time']:.3f}")

        print(
            f"{entry['index']:>3}  {info.get('codec','?')+'/'+str(info.get('profile','?')):<12}"
            f" {info.get('rate',0):>6} {info.get('channels',0):>3}"
            f"  {info.get('duration',0):>8.2f} {drift:>+6.2f}"
            f"  {path.stat().st_size:>10} {mean:>7.1f} {peak:>7.1f}"
            f"  {'sauber' if not error else 'FEHLER'}"
        )
        for flag in flags:
            problems.append(f"Segment {entry['index']}: {flag}")

    print()
    if problems:
        print("Auffällig:")
        for problem in problems:
            print("  - " + problem)
    else:
        print("Nichts auffällig: alle geprüften Segmente decodieren sauber und tragen Ton.")

    if args.keep:
        print(f"\nDateien liegen in {target}")
        print(f"Anhören:  ffplay -autoexit {target}/{chosen[0]['index']:04d}.m4a")
    else:
        shutil.rmtree(target, ignore_errors=True)
    return 0


if __name__ == "__main__":
    sys.exit(main())
