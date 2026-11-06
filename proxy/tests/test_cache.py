import pytest

from abconnect_proxy.cache import Cache, UnsafeBookId


@pytest.fixture
def cache(tmp_path):
    return Cache(root=tmp_path / "cache")


def fill(cache: Cache, book_id: str, size: int = 1024) -> None:
    cache.store_manifest(book_id, {"book_id": book_id, "segments": []})
    path = cache.segment_path(book_id, "0000.mp3")
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

    def test_broken_manifest_counts_as_not_prepared(self, cache):
        cache.store_manifest("book", {"segments": []})
        cache.manifest_path("book").write_text("{broken", encoding="utf-8")
        assert cache.load_manifest("book") is None


def test_survives_a_restart(tmp_path):
    first = Cache(root=tmp_path / "cache")
    fill(first, "book")
    first.pin("book")

    second = Cache(root=tmp_path / "cache")
    assert second.is_ready("book")
    assert second.pinned("book")
