import pytest

from abconnect_proxy import config as config_module
from abconnect_proxy.abs_client import AbsError
from abconnect_proxy.cache import Cache
from abconnect_proxy.parsing import Playlist
from abconnect_proxy.preparer import BookState, Status
from abconnect_proxy.reconciler import PlaylistReconciler

from .conftest import write_users

pytestmark = pytest.mark.anyio


class FakeAbs:
    def __init__(self, playlist):
        self.playlist_value = playlist
        self.calls = 0
        self.asked_for = []

    async def playlist(self, name):
        self.calls += 1
        self.asked_for.append(name)
        if isinstance(self.playlist_value, Exception):
            raise self.playlist_value
        return self.playlist_value


class FakePreparer:
    def __init__(self, cache, states=None):
        self.cache = cache
        self.states = states or {}
        self.requested = []

    def status(self, book_id):
        return self.states.get(book_id, BookState())

    def request(self, book_id):
        self.requested.append(book_id)
        self.states[book_id] = BookState(status=Status.PREPARING)
        self.cache.pin(book_id)
        return self.states[book_id]


def make(tmp_path, playlist, states=None, playlist_name="Garmin"):
    users = write_users(
        tmp_path / "users.toml",
        {"alice": {"tokens": ["t" * 20], "abs_url": "https://abs.example", "abs_api_key": "k" * 20}},
    )
    cfg = config_module.load(
        {
            "USERS_FILE": str(users),
            "CACHE_DIR": str(tmp_path / "cache"),
            "WORK_DIR": str(tmp_path / "work"),
        }
    )
    cache = Cache(root=cfg.cache_dir)
    abs_client = FakeAbs(playlist)
    preparer = FakePreparer(cache, states)
    reconciler = PlaylistReconciler(
        abs_client=abs_client, cache=cache, preparer=preparer, config=cfg, playlist=playlist_name
    )
    return reconciler, cache, abs_client, preparer


def playlist_of(*ids):
    return Playlist(
        id="pl1",
        name="Garmin",
        book_ids=list(ids),
        books=[{"id": i, "title": i.upper(), "author": "A", "duration": 100.0} for i in ids],
    )


def cached(cache, book_id, pinned=True):
    cache.store_manifest(book_id, {"book_id": book_id, "segments": []})
    if pinned:
        cache.pin(book_id)
    else:
        cache.release(book_id)


async def test_asks_for_the_users_own_playlist(tmp_path):
    reconciler, _, abs_client, _ = make(tmp_path, playlist_of(), playlist_name="Uhr")

    await reconciler.reconcile()

    assert abs_client.asked_for == ["Uhr"]


class TestAdding:
    async def test_prepares_books_that_are_new_in_the_playlist(self, tmp_path):
        reconciler, _, _, preparer = make(tmp_path, playlist_of("li_a", "li_b"))

        result = await reconciler.reconcile()

        assert result.found
        assert preparer.requested == ["li_a", "li_b"]
        assert result.prepared == ["li_a", "li_b"]

    async def test_does_not_prepare_a_book_twice(self, tmp_path):
        reconciler, _, _, preparer = make(tmp_path, playlist_of("li_a"))

        await reconciler.reconcile()
        await reconciler.reconcile()

        assert preparer.requested == ["li_a"]

    async def test_repins_a_ready_book_that_returned_to_the_playlist(self, tmp_path):
        reconciler, cache, _, _ = make(
            tmp_path, playlist_of("li_a"), states={"li_a": BookState(status=Status.READY)}
        )
        cached(cache, "li_a", pinned=False)
        assert not cache.pinned("li_a")

        await reconciler.reconcile()

        # Without pinning again, the emergency brake would evict a book that
        # belongs on the watch according to the playlist.
        assert cache.pinned("li_a")

    async def test_leaves_an_errored_book_alone(self, tmp_path):
        reconciler, _, _, preparer = make(
            tmp_path, playlist_of("li_a"), states={"li_a": BookState(status=Status.ERROR, error="broken")}
        )

        await reconciler.reconcile()

        assert preparer.requested == []


class TestRemoving:
    async def test_releases_books_that_left_the_playlist(self, tmp_path):
        reconciler, cache, _, _ = make(tmp_path, playlist_of("li_a"))
        cached(cache, "li_a")
        cached(cache, "li_old")

        result = await reconciler.reconcile()

        assert result.released == ["li_old"]
        assert not cache.pinned("li_old")
        assert cache.is_ready("li_old")  # stays around until the TTL

    async def test_an_already_released_book_is_not_released_again(self, tmp_path):
        reconciler, cache, _, _ = make(tmp_path, playlist_of())
        cached(cache, "li_old", pinned=False)

        result = await reconciler.reconcile()

        assert result.released == []


class TestFailureIsNotEmptiness:
    async def test_a_missing_playlist_never_releases_anything(self, tmp_path):
        reconciler, cache, _, _ = make(tmp_path, None)
        cached(cache, "li_a")

        result = await reconciler.reconcile()

        assert not result.found
        assert "does not exist" in result.error
        assert result.released == []
        assert cache.pinned("li_a")

    async def test_an_unreachable_server_never_releases_anything(self, tmp_path):
        reconciler, cache, _, _ = make(tmp_path, AbsError("connection lost"))
        cached(cache, "li_a")

        result = await reconciler.reconcile()

        assert result.released == []
        assert cache.pinned("li_a")
        assert "connection lost" in result.error

    async def test_an_outage_keeps_reporting_the_last_known_playlist(self, tmp_path):
        reconciler, cache, abs_client, _ = make(tmp_path, playlist_of("li_a"))
        await reconciler.reconcile()

        abs_client.playlist_value = AbsError("connection lost")
        result = await reconciler.reconcile()

        assert result.found  # the last known state, not "empty"
        assert [b["id"] for b in result.books] == ["li_a"]
