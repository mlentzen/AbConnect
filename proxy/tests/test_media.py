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


def _encode(path, *, channels: int, bitrate_kbps: int, duration: float = 2) -> None:
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
            f"{bitrate_kbps}k",
            "-ac",
            str(channels),
            "-ar",
            "44100",
            str(path),
        ],
        check=True,
    )


class TestNeedsReencode:
    async def test_skips_a_file_that_is_already_mono_at_the_requested_rate(
        self, tmp_path
    ):
        source = tmp_path / "0000.mp3"
        _encode(source, channels=1, bitrate_kbps=64)

        assert await media.needs_reencode(source, 64, mono=True) is False

    async def test_reencodes_when_mono_is_asked_and_the_file_is_stereo(self, tmp_path):
        source = tmp_path / "0000.mp3"
        _encode(source, channels=2, bitrate_kbps=64)

        assert await media.needs_reencode(source, 64, mono=True) is True

    async def test_leaves_a_stereo_file_at_the_requested_rate(self, tmp_path):
        source = tmp_path / "0000.mp3"
        _encode(source, channels=2, bitrate_kbps=64)

        assert await media.needs_reencode(source, 64, mono=False) is False

    async def test_reencodes_a_stereo_file_that_is_at_another_rate(self, tmp_path):
        source = tmp_path / "0000.mp3"
        _encode(source, channels=2, bitrate_kbps=128)

        assert await media.needs_reencode(source, 64, mono=False) is True

    async def test_reencodes_when_the_mono_file_is_at_another_rate(self, tmp_path):
        source = tmp_path / "0000.mp3"
        _encode(source, channels=1, bitrate_kbps=64)

        assert await media.needs_reencode(source, 32, mono=False) is True


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
        assert probed.channels == 1
        assert probed.bit_rate == pytest.approx(64000, rel=0.15)
        assert probed.duration == pytest.approx(20, abs=0.5)

    async def test_a_stereo_source_is_encoded_at_the_bitrate_per_channel(
        self, make_m4b, tmp_path
    ):
        book = make_m4b("reenc-stereo", 20, [(0, 20, "A")], channels=2)
        segment = tmp_path / "0000.mp3"

        await media.cut(book, segment, start=0, duration=10, bitrate_kbps=64)

        probed = probe(segment)
        assert probed.channels == 2
        assert probed.bit_rate == pytest.approx(128000, rel=0.15)

    async def test_replaygain_side_data_still_reports_the_channel_count(
        self, tmp_path
    ):
        """A LAME ReplayGain tag is stream side data. ffprobe's csv writer then
        appends a comma, so the channel line is ``2,`` rather than ``2``.
        """
        source = tmp_path / "rg.mp3"
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
                "sine=frequency=440:duration=2",
                "-c:a",
                "libmp3lame",
                "-b:a",
                "64k",
                "-ac",
                "2",
                "-metadata",
                "REPLAYGAIN_TRACK_GAIN=-6.00 dB",
                "-metadata",
                "REPLAYGAIN_TRACK_PEAK=0.900000",
                str(source),
            ],
            check=True,
        )
        segment = tmp_path / "0000.mp3"

        await media.cut(source, segment, start=0, duration=1, bitrate_kbps=64)

        probed = probe(segment)
        assert probed.channels == 2
        assert probed.bit_rate == pytest.approx(128000, rel=0.15)

    async def test_more_than_two_channels_is_mixed_down_to_stereo(
        self, make_m4b, tmp_path
    ):
        book = make_m4b("reenc-wide", 20, [(0, 20, "A")], channels=6)
        segment = tmp_path / "0000.mp3"

        await media.cut(book, segment, start=0, duration=10, bitrate_kbps=64)

        probed = probe(segment)
        assert probed.channels == 2
        assert probed.bit_rate == pytest.approx(128000, rel=0.15)

    async def test_to_mono_mixes_a_stereo_file_down_to_the_per_channel_rate(
        self, tmp_path
    ):
        """The shared cache stays stereo. Only the temporary copy is mono."""
        source = tmp_path / "0000.mp3"
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
                "sine=frequency=440:duration=2",
                "-c:a",
                "libmp3lame",
                "-b:a",
                "128k",
                "-ac",
                "2",
                "-ar",
                "44100",
                "-metadata",
                "title=The Stoker",
                "-metadata",
                "artist=Kafka",
                "-metadata",
                "album=Amerika",
                str(source),
            ],
            check=True,
        )
        before = source.read_bytes()
        destination = tmp_path / "pull.mp3"

        size = await media.reencode(source, destination, bitrate_kbps=64)

        assert size == destination.stat().st_size
        assert source.read_bytes() == before
        probed = probe(destination)
        assert probed.channels == 1
        assert probed.codec == "mp3"
        assert probed.sample_rate == 44100
        assert probed.bit_rate == pytest.approx(64000, rel=0.15)
        assert probed.duration == pytest.approx(2, abs=0.5)
        raw = subprocess.check_output(
            [
                "ffprobe",
                "-v",
                "error",
                "-print_format",
                "json",
                "-show_format",
                str(destination),
            ]
        )
        tags = {
            key.lower(): value
            for key, value in json.loads(raw)["format"].get("tags", {}).items()
        }
        assert tags.get("title") == "The Stoker"
        assert tags.get("album") == "Amerika"

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
