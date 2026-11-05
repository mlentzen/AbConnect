import asyncio
import dataclasses
import logging
import shutil
from pathlib import Path

import pytest

from abconnect_proxy import config as config_module
from abconnect_proxy import media
from abconnect_proxy.cache import Budget, Cache
from abconnect_proxy.models import Chapter, SourceFile
from abconnect_proxy.parsing import ItemUnusable, ParsedItem
from abconnect_proxy.preparer import Preparer, Status

from .conftest import needs_ffmpeg, probe, write_users

pytestmark = [needs_ffmpeg, pytest.mark.anyio]


class FakeAbs:
    """Provides a real m4b so ffmpeg actually has something to cut."""

    def __init__(self, item: ParsedItem, source: Path):
        self.item = item
        self.source = source
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


def make_config(
    tmp_path, *, cache_max_bytes: int | None = None
) -> config_module.Config:
    """Load a real configuration for one test.

    Args:
        tmp_path: Per-test directory. The users file, cache and work
            directory are created under it.
        cache_max_bytes: Override for the shared disk budget. Omit it to
            keep the loaded value.

    Returns:
        The configuration the preparer tests run with.
    """
    users = write_users(
        tmp_path / "users.toml",
        {
            "alice": {
                "tokens": ["t" * 20],
                "abs_url": "https://abs.example",
                "abs_api_key": "k" * 20,
            }
        },
    )
    base = config_module.load(
        {
            "USERS_FILE": str(users),
            "CACHE_DIR": str(tmp_path / "cache"),
            "WORK_DIR": str(tmp_path / "work"),
        }
    )
    if cache_max_bytes is None:
        return base
    return dataclasses.replace(base, cache_max_bytes=cache_max_bytes)


def preparer_for(abs_client, cache, cfg) -> Preparer:
    budget = Budget(max_bytes=cfg.cache_max_bytes, caches={"alice": cache})
    return Preparer(
        abs_client=abs_client,
        cache=cache,
        config=cfg,
        budget=budget,
        work_dir=cfg.work_dir,
    )


def parsed(
    files,
    chapters,
    *,
    title: str = "Der Process",
    author: str = "Franz Kafka",
) -> ParsedItem:
    return ParsedItem(
        title=title,
        author=author,
        duration=sum(f.duration for f in files),
        files=files,
        chapters=chapters,
    )


@pytest.fixture
def single_book(make_m4b):
    source = make_m4b(
        "prep-single", 60, [(0, 30, "Verhaftung"), (30, 60, "Untersuchung")]
    )
    item = parsed(
        [
            SourceFile(
                ino="9001",
                filename="buch.m4b",
                duration=60,
                size=source.stat().st_size,
            )
        ],
        [Chapter(0, 30, "Verhaftung"), Chapter(30, 60, "Untersuchung")],
    )
    return item, source


async def build(tmp_path, item, source, *, cache_max_bytes: int | None = None):
    cfg = make_config(tmp_path, cache_max_bytes=cache_max_bytes)
    cache = Cache(root=cfg.cache_dir)
    abs_client = FakeAbs(item, source)
    return preparer_for(abs_client, cache, cfg), cache, abs_client, cfg


async def run(preparer, book_id="li_1"):
    preparer.request(book_id)
    for _ in range(400):
        await asyncio.sleep(0.02)
        if preparer.status(book_id).status in (
            Status.READY,
            Status.ERROR,
            Status.WITHHELD,
        ):
            break
    return preparer.status(book_id)


class TestHappyPath:
    async def test_prepares_a_book_into_playable_segments(self, tmp_path, single_book):
        item, source = single_book
        preparer, cache, _, _ = await build(tmp_path, item, source)

        state = await run(preparer)

        assert state.status is Status.READY
        manifest = cache.load_manifest("li_1")
        assert [s["title"] for s in manifest["segments"]] == [
            "Verhaftung",
            "Untersuchung",
        ]
        assert manifest["chapter_source"] == "chapters"
        assert manifest["author"] == "Franz Kafka"

        for entry in manifest["segments"]:
            assert entry["file"].endswith(".mp3")
            path = cache.segment_path("li_1", entry["file"])
            assert path.exists() and path.stat().st_size == entry["bytes"]
            probed = probe(path)
            assert probed.codec == "mp3"
            assert probed.duration == pytest.approx(entry["duration"], abs=1.0)

    async def test_deletes_the_source_file_after_cutting(self, tmp_path, single_book):
        item, source = single_book
        preparer, _, _, cfg = await build(tmp_path, item, source)

        await run(preparer)

        leftovers = (
            [p for p in cfg.work_dir.rglob("*") if p.is_file()]
            if cfg.work_dir.exists()
            else []
        )
        assert leftovers == []

    async def test_names_each_segment_before_cutting_it(
        self, tmp_path, single_book, caplog, monkeypatch
    ):
        """A long encode has to say which segment it is on, before ffmpeg runs.

        Otherwise the log stops after the download and the job looks stuck.
        """
        item, source = single_book
        preparer, _, _, _ = await build(tmp_path, item, source)
        real_cut = media.cut
        seen: list[str] = []

        async def watching(*args, **kwargs):
            seen.append(caplog.text)
            return await real_cut(*args, **kwargs)

        monkeypatch.setattr("abconnect_proxy.preparer.cut", watching)

        with caplog.at_level(logging.INFO, logger="abconnect_proxy.preparer"):
            state = await run(preparer)

        assert state.status is Status.READY
        assert "downloaded" in seen[0]
        assert "buch.m4b" in seen[0]
        assert "segment 1/2" in seen[0]
        assert "Verhaftung" in seen[0]
        assert "segment 2/2" not in seen[0]
        assert "segment 2/2" in seen[1]
        assert "Untersuchung" in seen[1]

    async def test_a_chapterless_m4b_is_withheld(self, tmp_path, caplog):
        item = parsed(
            [SourceFile(ino="1", filename="b.m4b", duration=60, size=1)],
            [],
        )
        preparer, cache, abs_client, _ = await build(
            tmp_path, item, tmp_path / "unused"
        )

        state = await run(preparer)

        assert state.status is Status.WITHHELD
        assert "no chapter markers" in state.error
        assert cache.load_manifest("li_1") is None
        assert abs_client.downloads == []
        assert "not offered to the watch" in caplog.text


class TestMultiFile:
    async def test_downloads_each_file_once_and_keeps_segments_within_files(
        self, tmp_path, make_m4b
    ):
        source = make_m4b("prep-multi", 60, [(0, 60, "Teil")])
        size = source.stat().st_size
        item = parsed(
            [
                SourceFile(ino="1", filename="a.m4b", duration=60, size=size),
                SourceFile(ino="2", filename="b.m4b", duration=60, size=size),
            ],
            [Chapter(0, 60, "Erster Teil"), Chapter(60, 120, "Zweiter Teil")],
        )
        preparer, cache, abs_client, _ = await build(tmp_path, item, source)

        state = await run(preparer)

        assert state.status is Status.READY
        assert abs_client.downloads == ["1", "2"]
        manifest = cache.load_manifest("li_1")
        assert sum(s["duration"] for s in manifest["segments"]) == pytest.approx(
            120, abs=1
        )
        assert [s["index"] for s in manifest["segments"]] == sorted(
            s["index"] for s in manifest["segments"]
        )


class TestFailures:
    async def test_a_failed_cut_leaves_no_source_file_and_no_half_book(
        self, tmp_path, single_book, monkeypatch
    ):
        item, source = single_book
        preparer, cache, _, cfg = await build(tmp_path, item, source)

        async def explode(
            source,
            destination,
            *,
            start,
            duration,
            title="",
            artist="",
            album="",
            track=None,
            bitrate_kbps=None,
        ):
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

    async def test_an_errored_book_waits_for_the_cooldown(self, tmp_path, single_book):
        item, source = single_book
        preparer, _, abs_client, _ = await build(tmp_path, item, source)
        abs_client.fail_download = True
        await run(preparer)
        abs_client.fail_download = False

        state = await preparer.admit("li_1")

        assert state.status is Status.ERROR
        assert abs_client.downloads == []

    async def test_an_errored_book_is_tried_again_after_the_cooldown(
        self, tmp_path, single_book
    ):
        item, source = single_book
        preparer, cache, abs_client, _ = await build(tmp_path, item, source)
        preparer.retry_after = 0
        abs_client.fail_download = True
        await run(preparer)
        abs_client.fail_download = False

        state = await preparer.admit("li_1")
        assert state.status is Status.PREPARING
        for _ in range(400):
            await asyncio.sleep(0.02)
            if preparer.status("li_1").status is not Status.PREPARING:
                break

        assert preparer.status("li_1").status is Status.READY
        assert cache.is_ready("li_1")

    async def test_an_unusable_item_reports_the_reason(self, tmp_path, single_book):
        _, source = single_book
        preparer, _, _, _ = await build(tmp_path, ItemUnusable("eBook only"), source)

        state = await run(preparer)

        assert state.status is Status.WITHHELD
        assert "eBook" in state.error

    async def test_refuses_when_the_cache_budget_cannot_hold_the_book(
        self, tmp_path, single_book
    ):
        item, source = single_book
        preparer, _, _, _ = await build(tmp_path, item, source, cache_max_bytes=10)

        state = await run(preparer)

        assert state.status is Status.ERROR
        assert "space" in state.error


class TestLifecycle:
    async def test_a_second_request_does_not_download_again(
        self, tmp_path, single_book
    ):
        item, source = single_book
        preparer, _, abs_client, _ = await build(tmp_path, item, source)

        await run(preparer)
        preparer.request("li_1")
        await asyncio.sleep(0.05)

        assert abs_client.downloads == ["9001"]

    async def test_ready_state_survives_a_new_preparer(self, tmp_path, single_book):
        item, source = single_book
        preparer, _cache, _, cfg = await build(tmp_path, item, source)
        await run(preparer)

        fresh = preparer_for(FakeAbs(item, source), Cache(root=cfg.cache_dir), cfg)

        state = fresh.status("li_1")
        assert state.status is Status.READY
        assert state.segment_count == 2

    async def test_a_book_deleted_behind_its_back_is_pending_again(
        self, tmp_path, single_book
    ):
        """The shared budget may delete a book on behalf of another user's job,
        and nobody tells this preparer. The missing manifest has to be enough."""
        item, source = single_book
        preparer, cache, _, _ = await build(tmp_path, item, source)
        await run(preparer)

        cache.discard("li_1")

        assert preparer.status("li_1").status is Status.PENDING

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
    """An mp3 file is copied whole. Chapters in the metadata are ignored."""

    async def test_an_mp3_file_is_copied_whole(self, tmp_path, make_mp3):
        source = make_mp3("kapitel", 20, sample_rate=22050, channels=1)
        item = parsed(
            [
                SourceFile(
                    ino="1",
                    filename="Kapitel Eins.mp3",
                    duration=20,
                    size=source.stat().st_size,
                )
            ],
            [Chapter(0, 5, "Should not split"), Chapter(5, 20, "Nor this")],
        )
        preparer, cache, _, _ = await build(tmp_path, item, source)

        assert (await run(preparer)).status is Status.READY

        manifest = cache.load_manifest("li_1")
        assert manifest["chapter_source"] == "files"
        assert len(manifest["segments"]) == 1
        entry = manifest["segments"][0]
        assert entry["title"] == "Kapitel Eins"
        assert entry["duration"] == pytest.approx(20, abs=0.05)
        probed = probe(cache.segment_path("li_1", entry["file"]))
        assert probed.codec == "mp3"
        assert probed.sample_rate == 22050


class TestRecut:
    """Changed encoder settings reach a ready book only once its segments are gone.

    The segment cache outlives the container. Deleting a book's directory is
    how an operator makes the next playlist refresh cut it again.
    """

    async def test_a_deleted_book_is_cut_again(self, tmp_path, single_book):
        item, source = single_book
        preparer, cache, abs_client, cfg = await build(tmp_path, item, source)
        assert (await run(preparer)).status is Status.READY

        cache.discard("li_1")
        again = preparer_for(abs_client, cache, cfg)
        assert (await run(again)).status is Status.READY

        assert len(abs_client.downloads) == 2
        for entry in cache.load_manifest("li_1")["segments"]:
            assert entry["file"].endswith(".mp3")
            assert cache.segment_path("li_1", entry["file"]).exists()
