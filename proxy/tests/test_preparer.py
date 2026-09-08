import asyncio
import dataclasses
import shutil
from pathlib import Path

import pytest

from abconnect_proxy import config as config_module
from abconnect_proxy import media
from abconnect_proxy.cache import Cache
from abconnect_proxy.models import Chapter, SourceFile
from abconnect_proxy.parsing import ItemUnusable, ParsedItem
from abconnect_proxy.preparer import Preparer, Status

from .conftest import needs_ffmpeg

pytestmark = [needs_ffmpeg, pytest.mark.anyio]


class FakeAbs:
    """Provides a real m4b so ffmpeg actually has something to cut."""

    def __init__(self, item: ParsedItem, source: Path, cover: bytes | None = b"JPEG"):
        self.item = item
        self.source = source
        self.cover = cover
        self.downloads: list[str] = []
        self.fail_download = False

    async def get_item(self, book_id):
        if isinstance(self.item, Exception):
            raise self.item
        return self.item

    async def download_file(self, book_id, ino, destination, on_progress=None):
        if self.fail_download:
            from abconnect_proxy.abs_client import AbsError

            raise AbsError("connection lost")
        self.downloads.append(ino)
        destination.parent.mkdir(parents=True, exist_ok=True)
        shutil.copyfile(self.source, destination)
        size = destination.stat().st_size
        if on_progress:
            on_progress(size, size)
        return size

    async def get_cover(self, book_id, width=300):
        return self.cover


def make_config(tmp_path, **overrides) -> config_module.Config:
    """Real validation, then test dimensions.

    The production limits (segments from 60 s) get in the way here: the
    fixtures are one minute long. So load regularly first, keeping the
    validation under test, and then switch to test sizes.
    """
    base = config_module.load(
        {
            "ABS_URL": "https://abs.example",
            "ABS_API_KEY": "k" * 20,
            "ABCONNECT_TOKEN": "t" * 20,
            "CACHE_DIR": str(tmp_path / "cache"),
            "WORK_DIR": str(tmp_path / "work"),
        }
    )
    return dataclasses.replace(
        base,
        segment_target_seconds=20,
        segment_min_seconds=5,
        segment_max_seconds=60,
        **overrides,
    )


def parsed(files, chapters, **kwargs) -> ParsedItem:
    return ParsedItem(
        id=kwargs.get("id", "li_1"),
        title=kwargs.get("title", "Der Process"),
        author=kwargs.get("author", "Franz Kafka"),
        duration=sum(f.duration for f in files),
        files=files,
        chapters=chapters,
        has_cover=kwargs.get("has_cover", True),
    )


@pytest.fixture
def low_rate_source(make_m4b):
    """A source at 22050 Hz mono — the shape the watch would not play."""
    source = make_m4b(
        "prep-lowrate", 60, [(0, 30, "Verhaftung"), (30, 60, "Untersuchung")],
        sample_rate=22050, channels=1,
    )
    item = parsed(
        [SourceFile(ino="9002", filename="leise.m4b", duration=60,
                    size=source.stat().st_size, codec="aac")],
        [Chapter(0, 30, "Verhaftung"), Chapter(30, 60, "Untersuchung")],
    )
    return item, source


@pytest.fixture
def single_book(make_m4b):
    source = make_m4b("prep-single", 60, [(0, 30, "Verhaftung"), (30, 60, "Untersuchung")])
    item = parsed(
        [SourceFile(ino="9001", filename="buch.m4b", duration=60, size=source.stat().st_size, codec="aac")],
        [Chapter(0, 30, "Verhaftung"), Chapter(30, 60, "Untersuchung")],
    )
    return item, source


async def build(tmp_path, item, source, **config_overrides):
    cfg = make_config(tmp_path, **config_overrides)
    cache = Cache(root=cfg.cache_dir)
    abs_client = FakeAbs(item, source)
    return Preparer(abs_client=abs_client, cache=cache, config=cfg), cache, abs_client, cfg


async def run(preparer, book_id="li_1"):
    preparer.request(book_id)
    for _ in range(400):
        await asyncio.sleep(0.02)
        if preparer.status(book_id).status in (Status.READY, Status.ERROR):
            break
    return preparer.status(book_id)


class TestHappyPath:
    async def test_prepares_a_book_into_playable_segments(self, tmp_path, single_book):
        item, source = single_book
        preparer, cache, _, _ = await build(tmp_path, item, source)

        state = await run(preparer)

        assert state.status is Status.READY
        manifest = cache.load_manifest("li_1")
        assert [s["title"] for s in manifest["segments"]] == ["Verhaftung", "Untersuchung"]
        assert manifest["chapter_source"] == "chapters"
        assert manifest["author"] == "Franz Kafka"

        for entry in manifest["segments"]:
            path = cache.segment_path("li_1", entry["file"])
            assert path.exists() and path.stat().st_size == entry["bytes"]
            probed = await media.probe(path)
            assert probed.duration == pytest.approx(entry["duration"], abs=1.0)

    async def test_deletes_the_source_file_after_cutting(self, tmp_path, single_book):
        item, source = single_book
        preparer, _, _, cfg = await build(tmp_path, item, source)

        await run(preparer)

        leftovers = [p for p in cfg.work_dir.rglob("*") if p.is_file()] if cfg.work_dir.exists() else []
        assert leftovers == []

    async def test_stores_the_cover(self, tmp_path, single_book):
        item, source = single_book
        preparer, cache, _, _ = await build(tmp_path, item, source)

        await run(preparer)

        assert cache.cover_path("li_1").read_bytes() == b"JPEG"
        assert cache.load_manifest("li_1")["cover"] is True

    async def test_records_the_grid_fallback_in_the_manifest(self, tmp_path, make_m4b):
        source = make_m4b("prep-nochapters", 60, [(0, 60, "Alles")])
        item = parsed(
            [SourceFile(ino="1", filename="b.m4b", duration=60, size=source.stat().st_size, codec="aac")],
            [],
        )
        preparer, cache, _, _ = await build(tmp_path, item, source)

        await run(preparer)

        manifest = cache.load_manifest("li_1")
        assert manifest["chapter_source"] == "grid"
        assert "no chapter markers" in manifest["reason"]


class TestMultiFile:
    async def test_downloads_each_file_once_and_keeps_segments_within_files(self, tmp_path, make_m4b):
        source = make_m4b("prep-multi", 60, [(0, 60, "Teil")])
        size = source.stat().st_size
        item = parsed(
            [
                SourceFile(ino="1", filename="a.m4b", duration=60, size=size, codec="aac"),
                SourceFile(ino="2", filename="b.m4b", duration=60, size=size, codec="aac"),
            ],
            [Chapter(0, 60, "Erster Teil"), Chapter(60, 120, "Zweiter Teil")],
        )
        preparer, cache, abs_client, _ = await build(tmp_path, item, source)

        state = await run(preparer)

        assert state.status is Status.READY
        assert abs_client.downloads == ["1", "2"]
        manifest = cache.load_manifest("li_1")
        assert sum(s["duration"] for s in manifest["segments"]) == pytest.approx(120, abs=1)
        assert [s["index"] for s in manifest["segments"]] == sorted(s["index"] for s in manifest["segments"])


class TestFailures:
    async def test_a_failed_cut_leaves_no_source_file_and_no_half_book(
        self, tmp_path, single_book, monkeypatch
    ):
        item, source = single_book
        preparer, cache, _, cfg = await build(tmp_path, item, source)

        async def explode(*args, **kwargs):
            raise media.MediaError("ffmpeg refuses")

        monkeypatch.setattr("abconnect_proxy.preparer.cut", explode)

        state = await run(preparer)

        assert state.status is Status.ERROR
        assert "ffmpeg" in state.error
        assert not cache.is_ready("li_1")
        assert [p for p in cfg.work_dir.rglob("*") if p.is_file()] == []

    async def test_a_broken_download_surfaces_as_an_error(self, tmp_path, single_book):
        item, source = single_book
        preparer, cache, abs_client, _ = await build(tmp_path, item, source)
        abs_client.fail_download = True

        state = await run(preparer)

        assert state.status is Status.ERROR
        assert "connection lost" in state.error
        assert not cache.is_ready("li_1")

    async def test_an_unusable_item_reports_the_reason(self, tmp_path, single_book):
        _, source = single_book
        preparer, _, _, _ = await build(tmp_path, ItemUnusable("eBook only"), source)

        state = await run(preparer)

        assert state.status is Status.ERROR
        assert "eBook" in state.error

    async def test_refuses_when_the_cache_budget_cannot_hold_the_book(self, tmp_path, single_book):
        item, source = single_book
        preparer, _, _, _ = await build(tmp_path, item, source, cache_max_bytes=10)

        state = await run(preparer)

        assert state.status is Status.ERROR
        assert "space" in state.error


class TestLifecycle:
    async def test_a_second_request_does_not_download_again(self, tmp_path, single_book):
        item, source = single_book
        preparer, _, abs_client, _ = await build(tmp_path, item, source)

        await run(preparer)
        preparer.request("li_1")
        await asyncio.sleep(0.05)

        assert abs_client.downloads == ["9001"]

    async def test_ready_state_survives_a_new_preparer(self, tmp_path, single_book):
        item, source = single_book
        preparer, cache, _, cfg = await build(tmp_path, item, source)
        await run(preparer)

        fresh = Preparer(abs_client=FakeAbs(item, source), cache=Cache(root=cfg.cache_dir), config=cfg)

        state = fresh.status("li_1")
        assert state.status is Status.READY
        assert state.segment_count == 2

    async def test_requesting_pins_the_book(self, tmp_path, single_book):
        item, source = single_book
        preparer, cache, _, _ = await build(tmp_path, item, source)

        preparer.request("li_1")
        assert cache.pinned("li_1")
        await preparer.shutdown()

    async def test_shutdown_cancels_a_running_job(self, tmp_path, single_book):
        item, source = single_book
        preparer, cache, _, _ = await build(tmp_path, item, source)

        preparer.request("li_1")
        await preparer.shutdown()

        assert preparer.status("li_1").status is Status.PENDING
        assert not cache.is_ready("li_1")


class TestTranscoding:
    """A source the watch will not play must not reach it unchanged.

    The codec name from ABS says nothing about the sample rate, so the decision
    can only be made once the file is on disk.
    """

    async def test_a_22050_source_is_lifted_to_44100(self, tmp_path, low_rate_source):
        item, source = low_rate_source
        preparer, cache, _, _ = await build(tmp_path, item, source)

        assert (await run(preparer)).status is Status.READY

        manifest = cache.load_manifest("li_1")
        assert manifest["segments"]
        for entry in manifest["segments"]:
            probed = await media.probe(cache.segment_path("li_1", entry["file"]))
            assert probed.sample_rate == 44100
            assert media.conforms(probed)

    async def test_the_mp3_fallback_changes_container_and_manifest(self, tmp_path, low_rate_source):
        """Flipping the target must carry through to the file name the watch fetches."""
        item, source = low_rate_source
        preparer, cache, _, _ = await build(tmp_path, item, source, transcode_target="mp3")

        assert (await run(preparer)).status is Status.READY

        manifest = cache.load_manifest("li_1")
        for entry in manifest["segments"]:
            assert entry["encoding"] == "mp3"
            assert entry["file"].endswith(".mp3")
            path = cache.segment_path("li_1", entry["file"])
            assert path.exists() and path.stat().st_size == entry["bytes"]
            assert (await media.probe(path)).codec == "mp3"

    async def test_a_conforming_source_is_still_stream_copied(self, tmp_path, single_book):
        """The fast path must survive: no re-encode where none is needed."""
        item, source = single_book
        preparer, cache, _, _ = await build(tmp_path, item, source)

        assert (await run(preparer)).status is Status.READY

        manifest = cache.load_manifest("li_1")
        for entry in manifest["segments"]:
            assert entry["encoding"] == "m4a"
            assert entry["file"].endswith(".m4a")

    async def test_never_leaves_even_a_bad_source_untouched(self, tmp_path, low_rate_source):
        """The way back to pure stream copy, for when the format is ruled out."""
        item, source = low_rate_source
        preparer, cache, _, _ = await build(tmp_path, item, source, transcode_mode="never")

        assert (await run(preparer)).status is Status.READY

        manifest = cache.load_manifest("li_1")
        probed = await media.probe(cache.segment_path("li_1", manifest["segments"][0]["file"]))
        assert probed.sample_rate == 22050


class TestForcedRePrepare:
    """Changed encoder settings must be able to reach a book that is already ready.

    The segment cache outlives the container, so without this a book stays on
    the files it was first cut with no matter what the settings say.
    """

    async def test_a_plain_request_does_not_recut_a_ready_book(self, tmp_path, single_book):
        item, source = single_book
        preparer, _, abs_client, _ = await build(tmp_path, item, source)
        await run(preparer)

        preparer.request("li_1")
        assert len(abs_client.downloads) == 1

    async def test_force_recuts_and_picks_up_the_new_target(self, tmp_path, low_rate_source):
        item, source = low_rate_source
        # Cut first with the container the fallback below must move away from,
        # independent of whatever the global default currently is.
        preparer, cache, abs_client, _ = await build(tmp_path, item, source, transcode_target="m4a")
        assert (await run(preparer)).status is Status.READY
        assert cache.load_manifest("li_1")["segments"][0]["file"].endswith(".m4a")

        # Same cache, a preparer configured for the fallback container.
        cfg = make_config(tmp_path, transcode_target="mp3")
        again = Preparer(abs_client=abs_client, cache=cache, config=cfg)
        again.request("li_1", force=True)
        for _ in range(400):
            await asyncio.sleep(0.02)
            if again.status("li_1").status in (Status.READY, Status.ERROR):
                break

        assert again.status("li_1").status is Status.READY
        assert len(abs_client.downloads) == 2
        for entry in cache.load_manifest("li_1")["segments"]:
            assert entry["file"].endswith(".mp3")
            assert cache.segment_path("li_1", entry["file"]).exists()

    async def test_force_leaves_stale_segment_files_behind_nowhere(self, tmp_path, low_rate_source):
        """A re-cut into a different container must not leave the old files."""
        item, source = low_rate_source
        preparer, cache, abs_client, _ = await build(tmp_path, item, source, transcode_target="m4a")
        await run(preparer)

        cfg = make_config(tmp_path, transcode_target="mp3")
        again = Preparer(abs_client=abs_client, cache=cache, config=cfg)
        again.request("li_1", force=True)
        for _ in range(400):
            await asyncio.sleep(0.02)
            if again.status("li_1").status in (Status.READY, Status.ERROR):
                break

        leftover = list(cache.book_dir("li_1").glob("*.m4a"))
        assert leftover == []
