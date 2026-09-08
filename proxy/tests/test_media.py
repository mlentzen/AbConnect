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
