import pytest

from abconnect_proxy import config as config_module
from abconnect_proxy.abs_client import AbsError
from abconnect_proxy.cache import Cache
from abconnect_proxy.parsing import Playlist
from abconnect_proxy.preparer import BookState, Status
from abconnect_proxy.watcher import Holdings, PlaylistWatcher

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

    async def admit(self, book_id, client=None):
        state = self.status(book_id)
        if state.status is Status.WITHHELD:
            return state
        if state.status is Status.READY:
            self.cache.pin(book_id)
            return state
        if state.status is Status.PENDING:
            return self.request(book_id)
        return state

    async def abandon(self, book_id):
        self.states.pop(book_id, None)
        self.cache.discard(book_id)


def make(tmp_path, playlist, states=None, playlist_name="Garmin"):
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
    watcher = PlaylistWatcher(
        abs_client=abs_client,
        cache=cache,
        preparer=preparer,
        config=cfg,
        playlist=playlist_name,
    )
    return watcher, cache, abs_client, preparer


def playlist_of(*ids):
    return Playlist(
        name="Garmin",
        books=[
            {"id": i, "title": i.upper(), "author": "A", "duration": 100.0} for i in ids
        ],
    )


def cached(cache, book_id, pinned=True):
    cache.store_manifest(book_id, {"book_id": book_id, "segments": []})
    if pinned:
        cache.pin(book_id)


async def test_asks_for_the_users_own_playlist(tmp_path):
    watcher, _, abs_client, _ = make(tmp_path, playlist_of(), playlist_name="Uhr")

    await watcher.refresh()

    assert abs_client.asked_for == ["Uhr"]


class TestAdding:
    async def test_prepares_books_that_are_new_in_the_playlist(self, tmp_path):
        watcher, _, _, preparer = make(tmp_path, playlist_of("li_a", "li_b"))

        result = await watcher.refresh()

        assert result.found
        assert preparer.requested == ["li_a", "li_b"]
        assert result.prepared == ["li_a", "li_b"]

    async def test_does_not_prepare_a_book_twice(self, tmp_path):
        watcher, _, _, preparer = make(tmp_path, playlist_of("li_a"))

        await watcher.refresh()
        await watcher.refresh()

        assert preparer.requested == ["li_a"]

    async def test_repins_a_ready_book_that_returned_to_the_playlist(self, tmp_path):
        watcher, cache, _, _ = make(
            tmp_path,
            playlist_of("li_a"),
            states={"li_a": BookState(status=Status.READY)},
        )
        cached(cache, "li_a", pinned=False)
        assert not cache.pinned("li_a")

        await watcher.refresh()

        # Without pinning again, the emergency brake would delete a book that
        # belongs on the watch according to the playlist.
        assert cache.pinned("li_a")

    async def test_leaves_an_errored_book_alone(self, tmp_path):
        watcher, _, _, preparer = make(
            tmp_path,
            playlist_of("li_a"),
            states={"li_a": BookState(status=Status.ERROR, error="broken")},
        )

        await watcher.refresh()

        assert preparer.requested == []

    async def test_a_withheld_book_is_left_out_and_released(self, tmp_path):
        watcher, cache, _, preparer = make(
            tmp_path,
            playlist_of("li_a", "li_b"),
            states={
                "li_b": BookState(
                    status=Status.WITHHELD, error="no chapter markers present"
                )
            },
        )
        cached(cache, "li_b")

        result = await watcher.refresh()

        assert [b["id"] for b in result.books] == ["li_a"]
        assert result.released == ["li_b"]
        assert not cache.pinned("li_b")
        assert preparer.requested == ["li_a"]


class TestRemoving:
    async def test_releases_books_that_left_the_playlist(self, tmp_path):
        watcher, cache, _, _ = make(tmp_path, playlist_of("li_a"))
        cached(cache, "li_a")
        cached(cache, "li_old")

        result = await watcher.refresh()

        assert result.released == ["li_old"]
        assert not cache.is_ready("li_old")

    async def test_a_book_already_off_the_playlist_is_deleted(self, tmp_path):
        watcher, cache, _, _ = make(tmp_path, playlist_of())
        cached(cache, "li_old", pinned=False)

        result = await watcher.refresh()

        assert result.released == ["li_old"]
        assert not cache.is_ready("li_old")


class TestFailureIsNotEmptiness:
    async def test_a_missing_playlist_never_releases_anything(self, tmp_path):
        watcher, cache, _, _ = make(tmp_path, None)
        cached(cache, "li_a")

        result = await watcher.refresh()

        assert not result.found
        assert "does not exist" in result.error
        assert result.released == []
        assert cache.pinned("li_a")

    async def test_an_unreachable_server_never_releases_anything(self, tmp_path):
        watcher, cache, _, _ = make(tmp_path, AbsError("connection lost"))
        cached(cache, "li_a")

        result = await watcher.refresh()

        assert result.released == []
        assert cache.pinned("li_a")
        assert "connection lost" in result.error

    async def test_an_outage_keeps_reporting_the_last_known_playlist(self, tmp_path):
        watcher, _cache, abs_client, _ = make(tmp_path, playlist_of("li_a"))
        await watcher.refresh()

        abs_client.playlist_value = AbsError("connection lost")
        result = await watcher.refresh()

        assert result.found  # the last known state, not "empty"
        assert [b["id"] for b in result.books] == ["li_a"]


def couple(tmp_path, alice_playlist, bob_playlist):
    """Two watches, one cache: a book stays while either playlist lists it."""
    users = write_users(
        tmp_path / "users.toml",
        {
            "alice": {
                "tokens": ["a" * 20],
                "abs_url": "https://abs.example",
                "abs_api_key": "k" * 20,
            },
            "bob": {
                "tokens": ["b" * 20],
                "abs_url": "https://abs.example",
                "abs_api_key": "b" * 20,
            },
        },
    )
    cfg = config_module.load(
        {
            "USERS_FILE": str(users),
            "CACHE_DIR": str(tmp_path / "cache"),
            "WORK_DIR": str(tmp_path / "work"),
        }
    )
    cache = Cache(root=cfg.cache_dir)
    preparer = FakePreparer(cache)
    holdings = Holdings()
    watchers = {}
    for name, playlist in (("alice", alice_playlist), ("bob", bob_playlist)):
        watchers[name] = PlaylistWatcher(
            abs_client=FakeAbs(playlist),
            cache=cache,
            preparer=preparer,
            config=cfg,
            playlist="Garmin",
            user=name,
            holdings=holdings,
        )
    return watchers["alice"], watchers["bob"], cache


async def test_a_book_another_user_still_has_is_kept(tmp_path):
    alice, bob, cache = couple(tmp_path, playlist_of("li_a"), playlist_of("li_shared"))
    cached(cache, "li_shared")

    await alice.refresh()
    await bob.refresh()
    alice.abs_client.playlist_value = playlist_of()
    result = await alice.refresh()

    # li_a left with Alice. li_shared is still on Bob's playlist.
    assert result.released == ["li_a"]
    assert cache.books() == ["li_shared"]
    assert cache.is_ready("li_shared")


async def test_a_book_is_kept_until_every_playlist_has_been_read(tmp_path):
    alice, _bob, cache = couple(tmp_path, playlist_of("li_a"), playlist_of("li_b"))
    cached(cache, "li_b")

    result = await alice.refresh()

    assert result.released == []
    assert cache.is_ready("li_b")


async def test_a_book_no_playlist_lists_is_released_once_every_playlist_is_known(
    tmp_path,
):
    alice, bob, cache = couple(tmp_path, playlist_of("li_a"), playlist_of())
    cached(cache, "li_old")

    await alice.refresh()
    assert cache.is_ready("li_old")

    result = await bob.refresh()

    assert result.released == ["li_old"]
    assert not cache.is_ready("li_old")


async def test_a_book_is_released_when_the_last_playlist_drops_it(tmp_path):
    alice, bob, cache = couple(
        tmp_path, playlist_of("li_a", "li_shared"), playlist_of("li_shared")
    )
    cached(cache, "li_a")
    cached(cache, "li_shared")
    await alice.refresh()
    await bob.refresh()

    alice.abs_client.playlist_value = playlist_of("li_a")
    await alice.refresh()
    assert cache.is_ready("li_shared")

    bob.abs_client.playlist_value = playlist_of()
    result = await bob.refresh()

    assert result.released == ["li_shared"]
    assert not cache.is_ready("li_shared")
    assert cache.is_ready("li_a")


async def test_an_unreachable_server_does_not_forget_that_users_books(tmp_path):
    alice, bob, cache = couple(tmp_path, playlist_of("li_a"), playlist_of("li_b"))
    cached(cache, "li_a")
    cached(cache, "li_b")
    await alice.refresh()
    await bob.refresh()

    bob.abs_client.playlist_value = AbsError("connection lost")
    await bob.refresh()
    await alice.refresh()

    assert cache.is_ready("li_b")


async def test_only_the_first_fifty_books_belong_on_the_watch(tmp_path):
    ids = [f"li_{i:03d}" for i in range(60)]
    watcher, cache, _, preparer = make(tmp_path, playlist_of(*ids))
    cached(cache, ids[59])

    result = await watcher.refresh()

    assert [b["id"] for b in result.books] == ids[:50]
    assert preparer.requested == ids[:50]
    assert result.released == [ids[59]]
    assert not cache.pinned(ids[59])
