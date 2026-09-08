import shutil
import subprocess
from pathlib import Path

import pytest

FFMPEG = shutil.which("ffmpeg") is not None and shutil.which("ffprobe") is not None
needs_ffmpeg = pytest.mark.skipif(not FFMPEG, reason="ffmpeg/ffprobe nicht verfügbar")


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
    """Erzeugt eine echte m4b mit Kapitelmarken — Testdaten, die ffmpeg glaubt."""

    root = tmp_path_factory.mktemp("fixtures")

    def _make(name: str, duration: float, chapters: list[tuple[float, float, str]]) -> Path:
        target = root / f"{name}.m4b"
        if target.exists():
            return target
        meta = root / f"{name}.txt"
        meta.write_text(_metadata(chapters), encoding="utf-8")
        subprocess.run(
            [
                "ffmpeg", "-nostdin", "-v", "error", "-y",
                "-f", "lavfi", "-i", f"sine=frequency=440:duration={duration}",
                "-i", str(meta), "-map_metadata", "1",
                "-c:a", "aac", "-b:a", "32k", str(target),
            ],
            check=True,
        )
        return target

    return _make


@pytest.fixture
def anyio_backend():
    return "asyncio"
