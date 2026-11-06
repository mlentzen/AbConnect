from __future__ import annotations

import asyncio
import json
import shutil
from collections.abc import Sequence
from pathlib import Path


class MediaError(Exception):
    """ffmpeg failed, or the file has nothing the watch can play."""


#: Rate written into every segment. Other rates are not played.
SAMPLE_RATE = 44100


def ensure_available() -> None:
    """Check that ffmpeg is on PATH.

    Raises:
        MediaError: ffmpeg is missing.
    """
    if shutil.which("ffmpeg") is None:
        raise MediaError("Not found in PATH: ffmpeg")


async def _run(command: Sequence[str]) -> bytes:
    process = await asyncio.create_subprocess_exec(
        *command, stdout=asyncio.subprocess.PIPE, stderr=asyncio.subprocess.PIPE
    )
    try:
        stdout, stderr = await process.communicate()
    except asyncio.CancelledError:
        process.kill()
        await process.wait()
        raise
    if process.returncode != 0:
        detail = stderr.decode(errors="replace").strip().splitlines()
        raise MediaError(
            f"{command[0]} failed ({process.returncode}): {detail[-1] if detail else '?'}"
        )
    return stdout


async def _channel_count(source: Path) -> int:
    """Read how many channels the first audio stream has.

    Args:
        source: File to inspect.

    Returns:
        The channel count, at least 1.

    Raises:
        MediaError: ffprobe failed, or the stream reports no channels.
    """
    stdout = await _run(
        [
            "ffprobe",
            "-v",
            "error",
            "-select_streams",
            "a:0",
            "-show_entries",
            "stream=channels",
            "-of",
            "json",
            str(source),
        ]
    )
    try:
        count = int(json.loads(stdout)["streams"][0]["channels"])
    except (json.JSONDecodeError, KeyError, IndexError, TypeError, ValueError):
        raise MediaError(f"{source.name} has no audio channel count") from None
    if count < 1:
        raise MediaError(f"{source.name} has no audio channels")
    return count


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
    bitrate_kbps: int | None = None,
) -> int:
    """Cut ``[start, start + duration)`` out of a source file.

    Without a bitrate this is a stream copy and therefore lossless. With one,
    the segment is re-encoded to mp3 at ``SAMPLE_RATE``. That bitrate is per
    channel: mono keeps it, stereo gets twice as much. mp3 holds at most two
    channels, so a wider source is mixed down to stereo first. The watch path
    always passes a bitrate.

    Args:
        source: File to cut from.
        destination: Where the segment is written.
        start: Start of the cut in the source file, in seconds.
        duration: Length of the cut, in seconds.
        title: Title tag. Empty writes no title.
        artist: Artist tag. Empty writes none.
        album: Album tag. Empty writes none.
        track: Track number tag. Omit it to write none.
        bitrate_kbps: mp3 bitrate in kbit/s for one channel. Omit it to
            stream-copy.

    Returns:
        The size of the segment file, in bytes.

    Raises:
        MediaError: ffmpeg failed, or the segment file is missing or empty.
    """
    destination.parent.mkdir(parents=True, exist_ok=True)
    command = [
        "ffmpeg",
        "-nostdin",
        "-v",
        "error",
        "-y",
        "-ss",
        f"{start:.3f}",  # before -i: fast input seeking
        "-i",
        str(source),
        "-t",
        f"{duration:.3f}",
        "-map",
        "0:a:0",
        "-map_metadata",
        "-1",  # drop source tags, we set our own
        "-map_chapters",
        "-1",  # no chapters in the segment
    ]
    if bitrate_kbps is None:
        command += ["-c", "copy"]
    else:
        channels = await _channel_count(source)
        # One channel keeps the given rate. Two or more share a stereo file,
        # so the file bitrate is twice the per-channel rate.
        file_bitrate = bitrate_kbps if channels == 1 else bitrate_kbps * 2
        # -write_xing keeps the duration readable without scanning the file.
        command += [
            "-c:a",
            "libmp3lame",
            "-b:a",
            f"{file_bitrate}k",
            "-ar",
            str(SAMPLE_RATE),
            "-id3v2_version",
            "3",
            "-write_xing",
            "1",
        ]
        if channels > 2:
            command += ["-ac", "2"]
    # Tags are not decoration: Garmin states that files without them may not be
    # shown by the watch at all. They have to survive the re-encode too.
    for key, value in (("title", title), ("artist", artist), ("album", album)):
        if value:
            command += ["-metadata", f"{key}={value}"]
    if track is not None:
        command += ["-metadata", f"track={track}"]
    command.append(str(destination))

    await _run(command)
    if not destination.exists() or destination.stat().st_size == 0:
        raise MediaError(f"Segment {destination.name} stayed empty")
    return destination.stat().st_size
