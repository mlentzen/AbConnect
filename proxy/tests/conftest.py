import json
import shutil
import subprocess
from dataclasses import dataclass
from pathlib import Path

import pytest

from abconnect_proxy.models import Chapter

FFMPEG = shutil.which("ffmpeg") is not None and shutil.which("ffprobe") is not None
needs_ffmpeg = pytest.mark.skipif(not FFMPEG, reason="ffmpeg/ffprobe not available")


@dataclass(frozen=True)
class ProbedAudio:
    """What a test read back from a file ffmpeg just wrote."""

    duration: float
    codec: str
    chapters: list[Chapter]
    sample_rate: int


def probe(path: Path) -> ProbedAudio:
    """Read duration, codec, chapters and sample rate with ffprobe.

    Tests use this to check a file ffmpeg just wrote.
    """
    raw = subprocess.check_output(
        [
            "ffprobe",
            "-v",
            "error",
            "-print_format",
            "json",
            "-show_format",
            "-show_streams",
            "-show_chapters",
            str(path),
        ]
    )
    data = json.loads(raw)
    audio = next(
        (
            stream
            for stream in data.get("streams", [])
            if stream.get("codec_type") == "audio"
        ),
        None,
    )
    if audio is None:
        raise AssertionError(f"{path.name} contains no audio track")

    def whole(value) -> int:
        try:
            return int(float(value))
        except (TypeError, ValueError):
            return 0

    chapters = []
    for entry in data.get("chapters", []):
        try:
            start, end = float(entry["start_time"]), float(entry["end_time"])
        except (KeyError, TypeError, ValueError):
            continue
        title = (entry.get("tags") or {}).get("title") or f"Chapter {len(chapters) + 1}"
        chapters.append(Chapter(start=start, end=end, title=title))

    duration = float(
        data.get("format", {}).get("duration") or audio.get("duration") or 0
    )
    return ProbedAudio(
        duration=duration,
        codec=(audio.get("codec_name") or "").lower(),
        chapters=chapters,
        sample_rate=whole(audio.get("sample_rate")),
    )


def write_users(path: Path, users: dict[str, dict]) -> Path:
    """Write a users file.

    json.dumps produces valid TOML for the strings and string lists used here.

    Args:
        path: Where the file is written.
        users: User name mapped to that user's table. Keys are the users-file
            fields, such as tokens, abs_url and abs_api_key.

    Returns:
        The path that was written.
    """
    lines = []
    for name, entry in users.items():
        lines.append(f"[users.{json.dumps(name)}]")
        lines += [f"{key} = {json.dumps(value)}" for key, value in entry.items()]
    path.write_text("\n".join(lines) + "\n", encoding="utf-8")
    return path


def _metadata(chapters: list[tuple[float, float, str]]) -> str:
    lines = [";FFMETADATA1"]
    for start, end, title in chapters:
        lines += [
            "[CHAPTER]",
            "TIMEBASE=1/1000",
            f"START={int(start * 1000)}",
            f"END={int(end * 1000)}",
            f"title={title}",
        ]
    return "\n".join(lines) + "\n"


@pytest.fixture(scope="session")
def make_m4b(tmp_path_factory):
    """Creates a real m4b with chapter markers, test data that ffmpeg believes."""

    root = tmp_path_factory.mktemp("fixtures")

    def _make(
        name: str,
        duration: float,
        chapters: list[tuple[float, float, str]],
        sample_rate: int = 44100,
        channels: int = 2,
    ) -> Path:
        """Build an m4b ffmpeg will accept as a real audiobook.

        The defaults match what a watch accepts. Pass 22050 and 1 channel
        for a source the watch would not play.

        Args:
            name: File stem. The same name returns the file already built.
            duration: Length in seconds.
            chapters: Markers as (start, end, title), in seconds.
            sample_rate: Sample rate in Hz.
            channels: Channel count.

        Returns:
            Path of the m4b.
        """
        target = root / f"{name}.m4b"
        if target.exists():
            return target
        meta = root / f"{name}.txt"
        meta.write_text(_metadata(chapters), encoding="utf-8")
        subprocess.run(
            [
                "ffmpeg",
                "-nostdin",
                "-v",
                "error",
                "-y",
                "-f",
                "lavfi",
                "-i",
                f"sine=frequency=440:duration={duration}",
                "-i",
                str(meta),
                "-map_metadata",
                "1",
                "-c:a",
                "aac",
                "-b:a",
                "32k",
                "-ar",
                str(sample_rate),
                "-ac",
                str(channels),
                str(target),
            ],
            check=True,
        )
        return target

    return _make


@pytest.fixture(scope="session")
def make_mp3(tmp_path_factory):
    """Creates a real mp3, the shape an already-split audiobook arrives in."""

    root = tmp_path_factory.mktemp("mp3")

    def _make(
        name: str, duration: float, sample_rate: int = 44100, channels: int = 2
    ) -> Path:
        target = root / f"{name}.mp3"
        if target.exists():
            return target
        subprocess.run(
            [
                "ffmpeg",
                "-nostdin",
                "-v",
                "error",
                "-y",
                "-f",
                "lavfi",
                "-i",
                f"sine=frequency=440:duration={duration}",
                "-c:a",
                "libmp3lame",
                "-b:a",
                "64k",
                "-ar",
                str(sample_rate),
                "-ac",
                str(channels),
                str(target),
            ],
            check=True,
        )
        return target

    return _make


@pytest.fixture
def anyio_backend():
    return "asyncio"
