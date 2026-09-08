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
    """Liefert eine echte m4b, damit ffmpeg wirklich etwas zu schneiden hat."""

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

            raise AbsError("Verbindung weg")
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
    """Echte Validierung, danach Testmaße.

    Die Produktionsgrenzen (Segmente ab 60 s) sind hier hinderlich: die
    Fixtures sind eine Minute lang. Deshalb erst regulär laden, damit die
    Validierung mitgetestet bleibt, und dann auf Testgrößen umstellen.
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
        assert "keine Kapitelmarken" in manifest["reason"]


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
            raise media.MediaError("ffmpeg mag nicht")

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
        assert "Verbindung" in state.error
        assert not cache.is_ready("li_1")

    async def test_an_unusable_item_reports_the_reason(self, tmp_path, single_book):
        _, source = single_book
        preparer, _, _, _ = await build(tmp_path, ItemUnusable("nur eBook"), source)

        state = await run(preparer)

        assert state.status is Status.ERROR
        assert "eBook" in state.error

    async def test_refuses_when_the_cache_budget_cannot_hold_the_book(self, tmp_path, single_book):
        item, source = single_book
        preparer, _, _, _ = await build(tmp_path, item, source, cache_max_bytes=10)

        state = await run(preparer)

        assert state.status is Status.ERROR
        assert "Platz" in state.error


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
