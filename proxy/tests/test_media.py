import json

import pytest

from abconnect_proxy import media
from abconnect_proxy.media import MediaError

from .conftest import needs_ffmpeg

pytestmark = [needs_ffmpeg, pytest.mark.anyio]


async def test_probe_reads_duration_codec_and_chapters(make_m4b):
    book = make_m4b("probe", 60, [(0, 20, "First"), (20, 40, "Second"), (40, 60, "Third")])
    result = await media.probe(book)

    assert result.codec == "aac"
    assert result.duration == pytest.approx(60, abs=0.5)
    assert [c.title for c in result.chapters] == ["First", "Second", "Third"]
    assert result.chapters[1].start == pytest.approx(20, abs=0.05)


async def test_cut_produces_a_playable_segment_of_the_right_length(make_m4b, tmp_path):
    book = make_m4b("cut", 60, [(0, 30, "A"), (30, 60, "B")])
    segment = tmp_path / "0001.m4a"

    size = await media.cut(book, segment, start=30, duration=30, title="B", album="Book", track=2)

    assert size > 0
    probed = await media.probe(segment)
    assert probed.duration == pytest.approx(30, abs=0.5)
    assert probed.codec == "aac"
    assert probed.chapters == []  # chapters do not belong in the segment


async def test_cut_is_lossless(make_m4b, tmp_path):
    """Stream copy must not touch the bitrate — otherwise the cache calculation is wrong."""
    book = make_m4b("lossless", 60, [(0, 60, "Alles")])
    whole = tmp_path / "whole.m4a"
    await media.cut(book, whole, start=0, duration=60)

    assert whole.stat().st_size == pytest.approx(book.stat().st_size, rel=0.05)


async def test_probe_rejects_a_file_without_audio(tmp_path):
    broken = tmp_path / "broken.m4b"
    broken.write_bytes(b"not mp4")
    with pytest.raises(MediaError):
        await media.probe(broken)


class TestConformance:
    """Where the line runs between stream copy and re-encode.

    The measured failing case was AAC-LC at 22050 Hz mono: a file that decodes
    perfectly on a computer and stays silent on the watch.
    """

    async def test_a_44100_source_is_passed_through(self, make_m4b):
        book = make_m4b("conform-ok", 20, [(0, 20, "A")])
        assert media.conforms(await media.probe(book))

    async def test_a_22050_source_is_not(self, make_m4b):
        book = make_m4b("conform-low", 20, [(0, 20, "A")], sample_rate=22050, channels=1)
        probed = await media.probe(book)

        assert probed.sample_rate == 22050
        assert probed.channels == 1
        assert not media.conforms(probed)

    async def test_mono_alone_does_not_disqualify(self, make_m4b):
        """Mono is fine and halves what goes over Bluetooth — only the rate counts."""
        book = make_m4b("conform-mono", 20, [(0, 20, "A")], sample_rate=44100, channels=1)
        assert media.conforms(await media.probe(book))


class TestReencode:
    @pytest.mark.parametrize(
        "target,suffix,codec", [("m4a", ".m4a", "aac"), ("mp3", ".mp3", "mp3")]
    )
    async def test_cut_lifts_a_low_rate_source_to_44100(
        self, make_m4b, tmp_path, target, suffix, codec
    ):
        book = make_m4b("reenc-src", 30, [(0, 30, "A")], sample_rate=22050, channels=1)
        segment = tmp_path / f"0000{suffix}"

        size = await media.cut(
            book, segment, start=0, duration=20,
            title="A", artist="Autor", album="Buch", track=1,
            encode=media.EncodeSpec(target=target, bitrate_kbps=64),
        )

        assert size > 0
        probed = await media.probe(segment)
        assert probed.sample_rate == 44100
        assert probed.codec == codec
        assert probed.duration == pytest.approx(20, abs=0.5)
        assert media.conforms(probed)

    @pytest.mark.parametrize("target,suffix", [("m4a", ".m4a"), ("mp3", ".mp3")])
    async def test_reencode_keeps_the_tags(self, make_m4b, tmp_path, target, suffix):
        """Garmin says a file without metadata may not be shown at all."""
        book = make_m4b("reenc-tags", 30, [(0, 30, "A")], sample_rate=22050, channels=1)
        segment = tmp_path / f"0001{suffix}"

        await media.cut(
            book, segment, start=0, duration=20,
            title="Kapitel Eins", artist="Franz Kafka", album="Der Process", track=2,
            encode=media.EncodeSpec(target=target, bitrate_kbps=64),
        )

        raw = await media._run(
            "ffprobe", "-v", "error", "-print_format", "json", "-show_format", str(segment)
        )
        tags = {k.lower(): v for k, v in json.loads(raw)["format"].get("tags", {}).items()}
        assert tags.get("title") == "Kapitel Eins"
        assert tags.get("album") == "Der Process"
