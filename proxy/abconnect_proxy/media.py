"""ffmpeg/ffprobe binding.

Cutting is stream copy wherever the source allows it: no re-encode, no quality
loss, runtime in the range of fractions of a second. That is the assumption the
whole prepare mechanism rests on, and it holds for most files.

It does not hold for all of them. Audiobooks in particular are often encoded at
22050 Hz, which no Garmin sample or reference implementation ever ships and
which the watch appears not to decode. Those sources are re-encoded on the way
out — see `conforms()` for where the line runs.
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


#: Sample rates the watch is known to handle. Garmin's own audio-provider
#: sample ships 44100 Hz, and the one working third-party reference resamples
#: everything to 44100 Hz. Anything else is re-encoded rather than trusted.
ACCEPTED_SAMPLE_RATES = frozenset({44100, 48000})

#: Codecs that may be passed through untouched, given an acceptable rate.
#: AAC is only safe as plain LC — HE-AAC carries SBR/PS data the watch has
#: never been shown to decode.
ACCEPTED_CODECS = frozenset({"aac", "mp3"})


@dataclass(frozen=True)
class ProbeResult:
    duration: float
    codec: str
    chapters: list[Chapter]
    sample_rate: int = 0
    channels: int = 0
    bit_rate: int = 0
    profile: str = ""

    @property
    def summary(self) -> str:
        """One line for the log — the fields that decide stream copy vs re-encode."""
        return (
            f"{self.codec}/{self.profile or '?'} "
            f"{self.sample_rate} Hz, {self.channels} ch, {self.bit_rate // 1000} kbps"
        )


def conforms(result: ProbeResult) -> bool:
    """Whether the source can go to the watch untouched.

    Channel count is deliberately not part of this: mono is fine, and it halves
    what has to travel over Bluetooth.
    """
    if result.codec not in ACCEPTED_CODECS:
        return False
    if result.codec == "aac" and result.profile.upper() not in ("LC", ""):
        return False
    return result.sample_rate in ACCEPTED_SAMPLE_RATES


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

    def _int(value) -> int:
        try:
            return int(float(value))
        except (TypeError, ValueError):
            return 0

    return ProbeResult(
        duration=duration,
        codec=(audio.get("codec_name") or "").lower(),
        chapters=chapters,
        sample_rate=_int(audio.get("sample_rate")),
        channels=_int(audio.get("channels")),
        # Some containers report the rate only at format level.
        bit_rate=_int(audio.get("bit_rate")) or _int(data.get("format", {}).get("bit_rate")),
        profile=audio.get("profile") or "",
    )


@dataclass(frozen=True)
class EncodeSpec:
    """How a non-conforming source is to be re-encoded on the way out."""

    target: str          # "m4a" or "mp3"
    bitrate_kbps: int
    sample_rate: int = 44100


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
    encode: EncodeSpec | None = None,
) -> int:
    """Cuts out [start, start+duration). Returns the size.

    Without `encode` this is a stream copy and therefore lossless. With one, the
    segment is re-encoded to the given target — the escape hatch for sources the
    watch will not play as they are.
    """
    destination.parent.mkdir(parents=True, exist_ok=True)
    args = [
        "ffmpeg", "-nostdin", "-v", "error", "-y",
        "-ss", f"{start:.3f}",          # before -i: fast input seeking
        "-i", str(source),
        "-t", f"{duration:.3f}",
        "-map", "0:a:0",
        "-map_metadata", "-1",          # drop source tags, we set our own
        "-map_chapters", "-1",          # no chapters in the segment
    ]
    if encode is None:
        args += ["-c", "copy"]
    elif encode.target == "mp3":
        # -write_xing keeps the duration readable without scanning the file.
        args += [
            "-c:a", "libmp3lame",
            "-b:a", f"{encode.bitrate_kbps}k",
            "-ar", str(encode.sample_rate),
            "-id3v2_version", "3",
            "-write_xing", "1",
        ]
    else:
        args += [
            "-c:a", "aac",
            "-b:a", f"{encode.bitrate_kbps}k",
            "-ar", str(encode.sample_rate),
        ]
    if destination.suffix == ".m4a":
        # move moov to the front so the player does not have to seek to EOF.
        args += ["-movflags", "+faststart"]
    # Tags are not decoration: Garmin states that files without them may not be
    # shown by the watch at all. They have to survive the re-encode too.
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
