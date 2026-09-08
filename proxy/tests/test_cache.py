import json

import pytest

from abconnect_proxy.cache import Cache, UnsafeBookId


@pytest.fixture
def cache(tmp_path):
    return Cache(root=tmp_path / "cache")


def fill(cache: Cache, book_id: str, size: int = 1024) -> None:
    cache.store_manifest(book_id, {"book_id": book_id, "segments": []})
    path = cache.segment_path(book_id, "0000.m4a")
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_bytes(b"x" * size)


class TestSafety:
    @pytest.mark.parametrize("book_id", ["../escape", "a/b", "", "x" * 200])
    def test_rejects_ids_that_could_escape_the_cache(self, cache, book_id):
        with pytest.raises(UnsafeBookId):
            cache.book_dir(book_id)

    def test_rejects_segment_names_with_traversal(self, cache):
        with pytest.raises(UnsafeBookId):
            cache.segment_path("book", "../../etc/passwd")


class TestManifest:
    def test_ready_only_after_the_manifest_lands(self, cache):
        assert not cache.is_ready("book")
        cache.store_manifest("book", {"segments": [1]})
        assert cache.is_ready("book")
        assert cache.load_manifest("book") == {"segments": [1]}

    def test_manifest_write_is_atomic(self, cache):
        cache.store_manifest("book", {"segments": []})
        assert not list(cache.book_dir("book").glob("*.tmp"))

    def test_broken_manifest_counts_as_not_prepared(self, cache):
        cache.store_manifest("book", {"segments": []})
        cache.manifest_path("book").write_text("{broken", encoding="utf-8")
        assert cache.load_manifest("book") is None


class TestEviction:
    def test_sweep_drops_released_books_past_their_ttl(self, cache):
        fill(cache, "old")
        fill(cache, "fresh")
        cache.release("old", now=0)
        cache.release("fresh", now=100 * 86400)

        evicted = cache.sweep(ttl_days=30, now=100 * 86400)

        assert evicted == ["old"]
        assert cache.is_ready("fresh")

    def test_sweep_never_touches_pinned_books(self, cache):
        fill(cache, "selected")
        cache.release("selected", now=0)
        cache.pin("selected", now=0)

        assert cache.sweep(ttl_days=1, now=999 * 86400) == []
        assert cache.is_ready("selected")

    def test_budget_evicts_least_recently_used_first(self, cache):
        for name, access in (("a", 30.0), ("b", 10.0), ("c", 20.0)):
            fill(cache, name, size=1000)
            cache.touch(name, now=access)

        evicted = cache.enforce_budget(max_bytes=2200)

        assert evicted == ["b"]  # 3000 -> 2000 bytes, oldest access first

    def test_budget_leaves_pinned_books_alone_even_when_over(self, cache):
        fill(cache, "pinned", size=5000)
        cache.pin("pinned")

        assert cache.enforce_budget(max_bytes=10) == []
        assert cache.is_ready("pinned")

    def test_pinning_after_release_clears_the_release_marker(self, cache):
        fill(cache, "book")
        cache.release("book", now=0)
        cache.pin("book", now=1)
        assert cache.pinned("book")
        assert cache.sweep(ttl_days=0, now=999 * 86400) == []


def test_survives_a_restart(tmp_path):
    first = Cache(root=tmp_path / "cache")
    fill(first, "book")
    first.pin("book")

    second = Cache(root=tmp_path / "cache")
    assert second.is_ready("book")
    assert second.pinned("book")
