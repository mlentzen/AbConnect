import json
import subprocess

import pytest

from abconnect_proxy import media

from .conftest import needs_ffmpeg, probe

pytestmark = [needs_ffmpeg, pytest.mark.anyio]


async def test_cut_produces_a_playable_segment_of_the_right_length(make_m4b, tmp_path):
    book = make_m4b("cut", 60, [(0, 30, "A"), (30, 60, "B")])
    segment = tmp_path / "0001.m4b"
    assert [chapter.title for chapter in probe(book).chapters] == ["A", "B"]

    size = await media.cut(
        book, segment, start=30, duration=30, title="B", album="Book", track=2
    )

    assert size > 0
    probed = probe(segment)
    assert probed.duration == pytest.approx(30, abs=0.5)
    assert probed.codec == "aac"
    assert probed.chapters == []  # chapters do not belong in the segment


class TestReencode:
    async def test_cut_encodes_a_low_rate_source_to_44100_mp3(self, make_m4b, tmp_path):
        book = make_m4b("reenc-src", 30, [(0, 30, "A")], sample_rate=22050, channels=1)
        segment = tmp_path / "0000.mp3"

        size = await media.cut(
            book,
            segment,
            start=0,
            duration=20,
            title="A",
            artist="Autor",
            album="Buch",
            track=1,
            bitrate_kbps=64,
        )

        assert size > 0
        probed = probe(segment)
        assert probed.sample_rate == 44100
        assert probed.codec == "mp3"
        assert probed.duration == pytest.approx(20, abs=0.5)

    async def test_reencode_keeps_the_tags(self, make_m4b, tmp_path):
        """Garmin says a file without metadata may not be shown at all."""
        book = make_m4b("reenc-tags", 30, [(0, 30, "A")], sample_rate=22050, channels=1)
        segment = tmp_path / "0001.mp3"

        await media.cut(
            book,
            segment,
            start=0,
            duration=20,
            title="Kapitel Eins",
            artist="Franz Kafka",
            album="Der Process",
            track=2,
            bitrate_kbps=64,
        )

        raw = subprocess.check_output(
            [
                "ffprobe",
                "-v",
                "error",
                "-print_format",
                "json",
                "-show_format",
                str(segment),
            ]
        )
        tags = {
            key.lower(): value
            for key, value in json.loads(raw)["format"].get("tags", {}).items()
        }
        assert tags.get("title") == "Kapitel Eins"
        assert tags.get("album") == "Der Process"
