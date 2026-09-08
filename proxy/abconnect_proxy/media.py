"""ffmpeg/ffprobe binding.

Cutting is done exclusively via stream copy: no re-encode, no quality loss,
runtime in the range of fractions of a second. That is the assumption the
whole prepare mechanism rests on.
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
        raise MediaError(f"Not found in PATH: {', '.join(missing)}")


async def _run(*args: str) -> bytes:
    process = await asyncio.create_subprocess_exec(
        *args, stdout=asyncio.subprocess.PIPE, stderr=asyncio.subprocess.PIPE
    )
    stdout, stderr = await process.communicate()
    if process.returncode != 0:
        detail = stderr.decode(errors="replace").strip().splitlines()
        raise MediaError(f"{args[0]} failed ({process.returncode}): {detail[-1] if detail else '?'}")
    return stdout


async def probe(path: Path) -> ProbeResult:
    raw = await _run(
        "ffprobe", "-v", "error", "-print_format", "json",
        "-show_format", "-show_streams", "-show_chapters", str(path),
    )
    data = json.loads(raw)

    audio = next((s for s in data.get("streams", []) if s.get("codec_type") == "audio"), None)
    if audio is None:
        raise MediaError(f"{path.name} contains no audio track")

    duration = float(data.get("format", {}).get("duration") or audio.get("duration") or 0.0)
    if duration <= 0:
        raise MediaError(f"{path.name} reports no duration")

    chapters = []
    for entry in data.get("chapters", []):
        try:
            start, end = float(entry["start_time"]), float(entry["end_time"])
        except (KeyError, TypeError, ValueError):
            continue
        title = (entry.get("tags") or {}).get("title") or f"Chapter {len(chapters) + 1}"
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
    """Cuts out [start, start+duration) losslessly. Returns the size."""
    destination.parent.mkdir(parents=True, exist_ok=True)
    args = [
        "ffmpeg", "-nostdin", "-v", "error", "-y",
        "-ss", f"{start:.3f}",          # before -i: fast input seeking
        "-i", str(source),
        "-t", f"{duration:.3f}",
        "-map", "0:a:0",
        "-map_metadata", "-1",          # drop source tags, we set our own
        "-map_chapters", "-1",          # no chapters in the segment
        "-c", "copy",
    ]
    if destination.suffix == ".m4a":
        # move moov to the front so the player does not have to seek to EOF.
        args += ["-movflags", "+faststart"]
    for key, value in (("title", title), ("artist", artist), ("album", album)):
        if value:
            args += ["-metadata", f"{key}={value}"]
    if track is not None:
        args += ["-metadata", f"track={track}"]
    args.append(str(destination))

    await _run(*args)
    if not destination.exists() or destination.stat().st_size == 0:
        raise MediaError(f"Segment {destination.name} stayed empty")
    return destination.stat().st_size
