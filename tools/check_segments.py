#!/usr/bin/env python3
"""Checks a book's segments on your own machine.

On the watch there is no telling whether a file is broken or the device simply
does not like it. Here the two can be separated:

* ffprobe reads the header — codec, profile, sample rate, channels, duration.
* A full decode run (``-f null``) finds breaks in the stream that the header
  does not show.
* volumedetect answers the question ffprobe does not ask: is there any sound in
  there at all, or is it 15 minutes of silence?

Usage::

    tools/check_segments.py                 # show the playlist
    tools/check_segments.py <book-id>       # check the first 3 segments
    tools/check_segments.py <book-id> --all
    tools/check_segments.py <book-id> --keep /tmp/seg   # keep the files

PROXY_URL and PROXY_TOKEN come from the environment or from app/.env.
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

# What the watch demonstrably accepts is not documented. These are the values
# that are customary in practice for Garmin music watches; anything else is only
# flagged, not counted as an error.
EXPECTED_RATES = {44100, 48000}

# 22050 Hz was the value that broke playback on the fenix 7X: the file decodes
# cleanly everywhere else and stays silent on the watch. The flag below is what
# caught it, so it stays even once the proxy resamples.


def load_env() -> tuple[str, str]:
    """Environment beats .env — otherwise as in build.sh."""
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
        sys.exit("PROXY_URL/PROXY_TOKEN missing (environment or app/.env).")
    return url.rstrip("/"), token


def get(url: str, token: str, path: str) -> bytes:
    request = urllib.request.Request(url + path, headers={"Authorization": f"Bearer {token}"})
    try:
        with urllib.request.urlopen(request, timeout=120) as response:
            return response.read()
    except urllib.error.HTTPError as error:
        sys.exit(f"HTTP {error.code} for {path}: {error.read()[:200].decode('utf-8', 'replace')}")


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
    """Decode in full. An empty string means: ran through cleanly."""
    out = subprocess.run(
        ["ffmpeg", "-v", "error", "-i", str(path), "-f", "null", "-"],
        capture_output=True, text=True,
    )
    return " ".join(out.stderr.split())[:120]


def loudness(path: Path) -> tuple[float, float]:
    """(mean, peak) volume in dB. -91 dB means: silence."""
    out = subprocess.run(
        ["ffmpeg", "-v", "info", "-i", str(path), "-af", "volumedetect", "-f", "null", "-"],
        capture_output=True, text=True,
    )
    mean = re.search(r"mean_volume:\s*(-?[\d.]+) dB", out.stderr)
    peak = re.search(r"max_volume:\s*(-?[\d.]+) dB", out.stderr)
    return (float(mean.group(1)) if mean else 0.0, float(peak.group(1)) if peak else 0.0)


def local_name(entry: dict) -> str:
    """Keep the suffix the proxy actually served.

    The container is no longer fixed: a source the watch cannot play is
    re-encoded, and the manifest says to what. Writing everything as .m4a would
    hand ffprobe an mp3 under the wrong name.
    """
    suffix = str(entry.get("encoding") or "").strip()
    if not suffix:
        suffix = Path(str(entry.get("url", ""))).suffix.lstrip(".") or "m4a"
    return f"{entry['index']:04d}.{suffix}"


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("book", nargs="?", help="book ID; without it the playlist is shown")
    parser.add_argument("--all", action="store_true", help="all segments instead of the first three")
    parser.add_argument("--limit", type=int, default=3)
    parser.add_argument("--keep", metavar="DIR", help="keep the files there instead of discarding them")
    args = parser.parse_args()

    for tool in ("ffprobe", "ffmpeg"):
        if shutil.which(tool) is None:
            sys.exit(f"{tool} not found.")

    url, token = load_env()

    if not args.book:
        data = json.loads(get(url, token, "/v1/playlist"))
        print(f"Playlist {data.get('playlist')!r} — {len(data.get('books', []))} books\n")
        for book in data.get("books", []):
            print(f"  {book['id']}  {book.get('status','?'):<10}  {book.get('title','')}")
        return 0

    listing = json.loads(get(url, token, f"/v1/books/{args.book}/segments"))
    segments = listing["segments"]
    chosen = segments if args.all else segments[: args.limit]
    print(f"{listing.get('title')} — {len(segments)} segments, checked: {len(chosen)}\n")

    target = Path(args.keep) if args.keep else Path(tempfile.mkdtemp(prefix="abconnect-"))
    target.mkdir(parents=True, exist_ok=True)

    header = f"{'Seg':>3}  {'Codec':<12} {'Rate':>6} {'Ch':>3}  {'Length':>8} {'Δ':>6}  {'Bytes':>10} {'Ø dB':>7} {'Max dB':>7}  Decode run"
    print(header)
    print("-" * len(header))

    problems: list[str] = []
    for entry in chosen:
        path = target / local_name(entry)
        path.write_bytes(get(url, token, entry["url"]))

        info = ffprobe(path)
        error = decode_check(path)
        mean, peak = loudness(path)
        drift = info.get("duration", 0) - float(entry["duration"])
        size_ok = path.stat().st_size == entry["bytes"]

        flags = []
        if info.get("rate") not in EXPECTED_RATES:
            flags.append(f"sample rate {info.get('rate')} unusual")
        if not size_ok:
            flags.append(f"size {path.stat().st_size} != manifest {entry['bytes']}")
        if abs(drift) > 1.0:
            flags.append(f"duration off by {drift:+.2f}s")
        if peak < -60:
            flags.append("practically silent")
        if error:
            flags.append(f"decoder: {error}")
        if info.get("start_time", 0) > 0.01:
            flags.append(f"start_time {info['start_time']:.3f}")

        print(
            f"{entry['index']:>3}  {info.get('codec','?')+'/'+str(info.get('profile','?')):<12}"
            f" {info.get('rate',0):>6} {info.get('channels',0):>3}"
            f"  {info.get('duration',0):>8.2f} {drift:>+6.2f}"
            f"  {path.stat().st_size:>10} {mean:>7.1f} {peak:>7.1f}"
            f"  {'clean' if not error else 'ERROR'}"
        )
        for flag in flags:
            problems.append(f"segment {entry['index']}: {flag}")

    print()
    if problems:
        print("Notable:")
        for problem in problems:
            print("  - " + problem)
    else:
        print("Nothing notable: every segment checked decodes cleanly and carries sound.")

    if args.keep:
        print(f"\nFiles are in {target}")
        print(f"Listen:  ffplay -autoexit {target}/{local_name(chosen[0])}")
    else:
        shutil.rmtree(target, ignore_errors=True)
    return 0


if __name__ == "__main__":
    sys.exit(main())
