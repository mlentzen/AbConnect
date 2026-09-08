"""ffmpeg/ffprobe-Anbindung.

Geschnitten wird ausschließlich per Stream-Copy: kein Re-Encode, kein
Qualitätsverlust, Laufzeit im Bereich von Sekundenbruchteilen. Das ist die
Annahme, auf der die ganze Prepare-Mechanik ruht.
"""

from __future__ import annotations

import asyncio
import json
import logging
import shutil
from dataclasses import dataclass
from pathlib import Path

from .models import Chapter

log = logging.getLogger(__name__)


class MediaError(Exception):
    pass


@dataclass(frozen=True)
class ProbeResult:
    duration: float
    codec: str
    chapters: list[Chapter]


def ensure_available() -> None:
    missing = [tool for tool in ("ffmpeg", "ffprobe") if shutil.which(tool) is None]
    if missing:
        raise MediaError(f"Nicht im PATH gefunden: {', '.join(missing)}")


async def _run(*args: str) -> bytes:
    process = await asyncio.create_subprocess_exec(
        *args, stdout=asyncio.subprocess.PIPE, stderr=asyncio.subprocess.PIPE
    )
    stdout, stderr = await process.communicate()
    if process.returncode != 0:
        detail = stderr.decode(errors="replace").strip().splitlines()
        raise MediaError(f"{args[0]} scheiterte ({process.returncode}): {detail[-1] if detail else '?'}")
    return stdout


async def probe(path: Path) -> ProbeResult:
    raw = await _run(
        "ffprobe", "-v", "error", "-print_format", "json",
        "-show_format", "-show_streams", "-show_chapters", str(path),
    )
    data = json.loads(raw)

    audio = next((s for s in data.get("streams", []) if s.get("codec_type") == "audio"), None)
    if audio is None:
        raise MediaError(f"{path.name} enthält keine Audiospur")

    duration = float(data.get("format", {}).get("duration") or audio.get("duration") or 0.0)
    if duration <= 0:
        raise MediaError(f"{path.name} meldet keine Dauer")

    chapters = []
    for entry in data.get("chapters", []):
        try:
            start, end = float(entry["start_time"]), float(entry["end_time"])
        except (KeyError, TypeError, ValueError):
            continue
        title = (entry.get("tags") or {}).get("title") or f"Kapitel {len(chapters) + 1}"
        chapters.append(Chapter(start=start, end=end, title=title))

    return ProbeResult(duration=duration, codec=audio.get("codec_name", ""), chapters=chapters)


async def cut(
    source: Path,
    destination: Path,
    *,
    start: float,
    duration: float,
    title: str = "",
    artist: str = "",
    album: str = "",
    track: int | None = None,
) -> int:
    """Schneidet [start, start+duration) verlustfrei heraus. Gibt die Größe zurück."""
    destination.parent.mkdir(parents=True, exist_ok=True)
    args = [
        "ffmpeg", "-nostdin", "-v", "error", "-y",
        "-ss", f"{start:.3f}",          # vor -i: schnelles Input-Seeking
        "-i", str(source),
        "-t", f"{duration:.3f}",
        "-map", "0:a:0",
        "-map_metadata", "-1",          # Quell-Tags verwerfen, wir setzen eigene
        "-map_chapters", "-1",          # keine Kapitel im Segment
        "-c", "copy",
    ]
    if destination.suffix == ".m4a":
        # moov nach vorn, damit der Player nicht ans Dateiende springen muss.
        args += ["-movflags", "+faststart"]
    for key, value in (("title", title), ("artist", artist), ("album", album)):
        if value:
            args += ["-metadata", f"{key}={value}"]
    if track is not None:
        args += ["-metadata", f"track={track}"]
    args.append(str(destination))

    await _run(*args)
    if not destination.exists() or destination.stat().st_size == 0:
        raise MediaError(f"Segment {destination.name} blieb leer")
    return destination.stat().st_size
