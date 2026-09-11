import json
import time

import httpx
import pytest
from fastapi.testclient import TestClient

from abconnect_proxy import config as config_module
from abconnect_proxy.abs_client import AbsClient
from abconnect_proxy.api import create_app
from abconnect_proxy.cache import USERS_DIR, Cache

from .conftest import write_users

TOKEN = "watch-token-abcdef"
HEAD = {"Authorization": f"Bearer {TOKEN}"}
# A second person on the same proxy, with their own server and playlist.
BOB_TOKEN = "bobs-watch-token-12"
BOB_HEAD = {"Authorization": f"Bearer {BOB_TOKEN}"}

LIBRARIES = {"libraries": [{"id": "lib1", "mediaType": "book"}]}
PLAYLISTS = {
    "playlists": [
        {
            "id": "pl1",
            "name": "Garmin",
            "items": [
                {
                    "libraryItemId": "li_a",
                    "libraryItem": {"media": {"duration": 3600, "metadata": {"title": "Amerika", "authorName": "Kafka"}}},
                }
            ],
        },
        {"id": "pl2", "name": "Other", "items": []},
    ]
}
BOB_PLAYLISTS = {
    "playlists": [
        {
            "id": "pl9",
            "name": "Bob",
            "items": [
                {
                    "libraryItemId": "li_x",
                    "libraryItem": {"media": {"duration": 5400, "metadata": {"title": "The Trial", "authorName": "Kafka"}}},
                }
            ],
        }
    ]
}
def abs_handler(progress_payload=None, on_patch=None, playlists=None):
    def handler(request: httpx.Request) -> httpx.Response:
        path = request.url.path
        if path == "/api/playlists":
            return httpx.Response(200, json=PLAYLISTS if playlists is None else playlists)
        if path == "/api/libraries":
            return httpx.Response(200, json=LIBRARIES)
        if path.startswith("/api/me/progress/"):
            if request.method == "PATCH":
                if on_patch is not None:
                    on_patch(json.loads(request.content))
                return httpx.Response(200, json={})
            if progress_payload is None:
                return httpx.Response(404, json={})
            return httpx.Response(200, json=progress_payload)
        return httpx.Response(404, json={})

    return handler


def bob_handler(**kwargs):
    return abs_handler(playlists=BOB_PLAYLISTS, **kwargs)


def load_config(tmp_path, alice_tokens=(TOKEN,)):
    users = write_users(
        tmp_path / "users.toml",
        {
            "alice": {"tokens": list(alice_tokens), "abs_url": "https://abs.alice.example", "abs_api_key": "k" * 20},
            "bob": {"tokens": [BOB_TOKEN], "abs_url": "https://abs.bob.example", "abs_api_key": "b" * 20, "playlist": "Bob"},
        },
    )
    return config_module.load(
        {
            "USERS_FILE": str(users),
            "CACHE_DIR": str(tmp_path / "cache"),
            "WORK_DIR": str(tmp_path / "work"),
        }
    )


@pytest.fixture
def config(tmp_path):
    return load_config(tmp_path)


def build_client(config, handler=None, bob=None):
    """Alice (TOKEN) and Bob (BOB_TOKEN) each talk to a mocked ABS of their own."""
    users = {user.name: user for user in config.users}
    handlers = {"alice": handler or abs_handler(), "bob": bob or bob_handler()}
    clients = {
        name: AbsClient(users[name].abs_url, users[name].abs_api_key, transport=httpx.MockTransport(h))
        for name, h in handlers.items()
    }
    return TestClient(create_app(config, abs_clients=clients))


def user_cache(config, user="alice"):
    return Cache(root=config.cache_dir / USERS_DIR / user)


def prepared_book(config, book_id="li_a", user="alice"):
    cache = user_cache(config, user)
    cache.store_manifest(
        book_id,
        {
            "book_id": book_id,
            "title": "Amerika",
            "author": "Kafka",
            "duration": 1800.0,
            "chapter_source": "chapters",
            "reason": "",
            "prepared_at": time.time(),
            "segments": [
                {"index": 0, "title": "The Stoker", "duration": 900.0, "book_start": 0.0,
                 "bytes": 7, "encoding": "m4a", "file": "0000.m4a"},
                {"index": 1, "title": "The Uncle", "duration": 900.0, "book_start": 900.0,
                 "bytes": 7, "encoding": "m4a", "file": "0001.m4a"},
            ],
        },
    )
    for name in ("0000.m4a", "0001.m4a"):
        path = cache.segment_path(book_id, name)
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_bytes(b"audio!!")
    return cache


class TestAuth:
    def test_v1_needs_a_token(self, config):
        with build_client(config) as client:
            assert client.get("/v1/playlist").status_code == 401

    def test_a_wrong_token_is_rejected(self, config):
        with build_client(config) as client:
            assert client.get("/v1/playlist", headers={"Authorization": "Bearer nope"}).status_code == 401

    def test_a_rotated_token_still_works(self, tmp_path):
        rotated = load_config(tmp_path, alice_tokens=("neu-token-1234567", TOKEN))
        with build_client(rotated) as client:
            assert client.get("/v1/playlist", headers=HEAD).status_code == 200
            assert client.get("/v1/playlist", headers={"Authorization": "Bearer neu-token-1234567"}).status_code == 200

    def test_repeated_failures_are_throttled(self, config):
        with build_client(config) as client:
            codes = [client.get("/v1/playlist", headers={"Authorization": "Bearer x"}).status_code for _ in range(7)]
        assert 429 in codes

    def test_health_needs_no_token(self, config):
        with build_client(config) as client:
            response = client.get("/health")
        assert response.status_code == 200
        assert response.json() == {"status": "ok"}


class TestPublicSurface:
    """What a stranger on the internet can reach without a token."""

    @pytest.mark.parametrize("path", ["/docs", "/redoc", "/openapi.json"])
    def test_api_docs_are_not_served(self, config, path):
        with build_client(config) as client:
            assert client.get(path).status_code == 404

    def test_an_oversized_body_is_refused_before_auth(self, config):
        with build_client(config) as client:
            response = client.post(
                "/v1/progress", content=b"x" * (70 * 1024), headers={"content-type": "application/json"}
            )
        assert response.status_code == 413

    def test_an_oversized_chunked_body_is_refused(self, config):
        def chunks():
            for _ in range(70):
                yield b"x" * 1024

        with build_client(config) as client:
            response = client.post("/v1/progress", content=chunks(), headers=HEAD)
        assert response.status_code == 413


class TestHealth:
    """/health only says the process answers; the details need a token."""

    def test_health_stays_bare_when_a_server_is_broken(self, config):
        def broken(request):
            return httpx.Response(500, json={})

        with build_client(config, broken) as client:
            response = client.get("/health")
        assert response.status_code == 200
        assert response.json() == {"status": "ok"}

    def test_health_names_no_user_playlist_or_server(self, config):
        with build_client(config) as client:
            body = client.get("/health").text
        for detail in ("alice", "bob", "Garmin", "abs.alice.example", "abs.bob.example"):
            assert detail not in body

    def test_status_needs_a_token(self, config):
        with build_client(config) as client:
            assert client.get("/v1/status").status_code == 401

    def test_status_reports_only_the_callers_own_state(self, config):
        with build_client(config) as client:
            response = client.get("/v1/status", headers=HEAD)
        assert response.status_code == 200
        payload = response.json()
        assert payload["audiobookshelf"] == "ok"
        assert payload["playlist"] == "Garmin"
        assert "users" not in payload
        assert "bob" not in response.text.lower()

    def test_a_broken_server_fails_only_its_owners_status(self, config):
        def broken(request):
            return httpx.Response(500, json={})

        with build_client(config, broken) as client:
            alice = client.get("/v1/status", headers=HEAD)
            bob = client.get("/v1/status", headers=BOB_HEAD)
        assert alice.status_code == 503
        assert alice.json()["audiobookshelf"] != "ok"
        assert bob.status_code == 200
        assert bob.json()["audiobookshelf"] == "ok"


class TestSegments:
    def test_unprepared_book_answers_with_conflict_not_a_crash(self, config):
        with build_client(config) as client:
            response = client.get("/v1/books/li_a/segments", headers=HEAD)
        assert response.status_code == 409
        # The exact state depends on whether the playlist reconciliation has
        # already run - what matters is that "not ready" is reported.
        assert "not ready" in response.json()["detail"]

    def test_returns_the_segment_list_with_urls(self, config):
        prepared_book(config)
        with build_client(config) as client:
            payload = client.get("/v1/books/li_a/segments", headers=HEAD).json()

        assert payload["title"] == "Amerika"
        assert [s["title"] for s in payload["segments"]] == ["The Stoker", "The Uncle"]
        assert payload["segments"][1]["url"] == "/v1/books/li_a/seg/0001.m4a"

    def test_includes_the_server_resume_point(self, config):
        prepared_book(config)
        handler = abs_handler(progress_payload={"currentTime": 1000.0, "lastUpdate": 1_700_000_000_000})
        with build_client(config, handler) as client:
            payload = client.get("/v1/books/li_a/segments", headers=HEAD).json()

        assert payload["resume"] == {"segment": 1, "offset": 100.0, "ts": 1_700_000_000.0}

    def test_serves_the_segment_file(self, config):
        prepared_book(config)
        with build_client(config) as client:
            response = client.get("/v1/books/li_a/seg/0000.m4a", headers=HEAD)
        assert response.status_code == 200
        assert response.content == b"audio!!"
        assert response.headers["content-type"] == "audio/mp4"

    def test_rejects_traversal_in_the_segment_name(self, config):
        prepared_book(config)
        with build_client(config) as client:
            response = client.get("/v1/books/li_a/seg/..%2F..%2Fetc%2Fpasswd", headers=HEAD)
        assert response.status_code in (400, 404)


class TestProgress:
    def test_pushes_the_watch_position_to_abs(self, config):
        prepared_book(config)
        sent = {}
        with build_client(config, abs_handler(on_patch=sent.update)) as client:
            payload = client.post(
                "/v1/progress",
                headers=HEAD,
                json={"entries": [{"book_id": "li_a", "segment": 1, "offset": 300, "ts": 1_700_000_000}]},
            ).json()

        assert payload["books"][0] == {"id": "li_a", "accepted": True, "source": "watch"}
        assert sent["currentTime"] == 1200.0  # 900 + 300

    def test_keeps_only_the_newest_entry_per_book(self, config):
        prepared_book(config)
        sent = {}
        with build_client(config, abs_handler(on_patch=sent.update)) as client:
            client.post(
                "/v1/progress",
                headers=HEAD,
                json={
                    "entries": [
                        {"book_id": "li_a", "segment": 0, "offset": 10, "ts": 1_700_000_000},
                        {"book_id": "li_a", "segment": 1, "offset": 10, "ts": 1_700_000_500},
                    ]
                },
            )
        assert sent["currentTime"] == 910.0

    def test_a_newer_server_position_wins_and_is_handed_back(self, config):
        prepared_book(config)
        handler = abs_handler(progress_payload={"currentTime": 1500.0, "lastUpdate": 1_800_000_000_000})
        with build_client(config, handler) as client:
            payload = client.post(
                "/v1/progress",
                headers=HEAD,
                json={"entries": [{"book_id": "li_a", "segment": 0, "offset": 5, "ts": 1_700_000_000}]},
            ).json()

        entry = payload["books"][0]
        assert entry["source"] == "server"
        assert entry["resume"] == {"segment": 1, "offset": 600.0}

    def test_a_zero_timestamp_only_asks_and_writes_nothing(self, config):
        prepared_book(config)
        sent = {}
        with build_client(config, abs_handler(on_patch=sent.update)) as client:
            payload = client.post(
                "/v1/progress",
                headers=HEAD,
                json={"entries": [{"book_id": "li_a", "segment": 0, "offset": 0, "ts": 0}]},
            ).json()

        assert payload["books"][0] == {"id": "li_a", "accepted": True, "source": "watch"}
        assert sent == {}

    def test_a_zero_timestamp_learns_the_server_position(self, config):
        prepared_book(config)
        handler = abs_handler(progress_payload={"currentTime": 1500.0, "lastUpdate": 1_800_000_000_000})
        with build_client(config, handler) as client:
            payload = client.post(
                "/v1/progress",
                headers=HEAD,
                json={"entries": [{"book_id": "li_a", "segment": 0, "offset": 0, "ts": 0}]},
            ).json()

        assert payload["books"][0]["resume"] == {"segment": 1, "offset": 600.0}

    def test_an_unsafe_book_id_is_rejected_not_crashed(self, config):
        with build_client(config) as client:
            response = client.post(
                "/v1/progress",
                headers=HEAD,
                json={"entries": [{"book_id": "../x", "segment": 0, "offset": 0, "ts": 1}]},
            )
        assert response.status_code == 422

    def test_an_unknown_book_is_reported_not_crashed(self, config):
        with build_client(config) as client:
            payload = client.post(
                "/v1/progress",
                headers=HEAD,
                json={"entries": [{"book_id": "li_zzz", "segment": 0, "offset": 0, "ts": 1}]},
            ).json()
        assert payload["books"][0]["accepted"] is False


class TestPlaylist:
    def test_reports_the_playlist_contents_with_status(self, config):
        prepared_book(config)
        with build_client(config) as client:
            payload = client.get("/v1/playlist", headers=HEAD).json()

        assert payload["playlist"] == "Garmin"
        assert payload["found"] is True
        assert [b["id"] for b in payload["books"]] == ["li_a"]
        assert payload["books"][0]["status"] == "ready"
        assert payload["books"][0]["title"] == "Amerika"

    def test_a_book_added_to_the_playlist_gets_prepared(self, config):
        with build_client(config) as client:
            payload = client.get("/v1/playlist", headers=HEAD).json()

        assert payload["books"][0]["status"] in ("preparing", "error")

    def test_a_book_removed_from_the_playlist_is_released(self, config):
        cache = prepared_book(config)
        prepared_book(config, book_id="li_gone")
        cache.pin("li_gone")

        with build_client(config) as client:
            client.get("/v1/playlist", headers=HEAD)

        assert not cache.pinned("li_gone")
        assert cache.pinned("li_a")

    def test_a_missing_playlist_answers_409_and_touches_nothing(self, config):
        cache = prepared_book(config)
        cache.pin("li_a")
        empty = {"playlists": [{"id": "pl2", "name": "Other", "items": []}]}

        with build_client(config, abs_handler(playlists=empty)) as client:
            response = client.get("/v1/playlist", headers=HEAD)

        assert response.status_code == 409
        assert response.json()["found"] is False
        assert "does not exist" in response.json()["error"]
        # What matters: the watch must not delete anything as a result.
        assert cache.pinned("li_a")

    def test_playlist_needs_a_token(self, config):
        with build_client(config) as client:
            assert client.get("/v1/playlist").status_code == 401

    def test_status_reports_whether_the_playlist_was_found(self, config):
        with build_client(config) as client:
            client.get("/v1/playlist", headers=HEAD)
            alice = client.get("/v1/status", headers=HEAD).json()
            bob = client.get("/v1/status", headers=BOB_HEAD).json()
        assert alice["playlist"] == "Garmin"
        assert alice["playlist_found"] is True
        assert bob["playlist"] == "Bob"


class TestIsolation:
    """Several people on one proxy: the token decides whose world a request sees."""

    def test_each_token_gets_its_own_playlist(self, config):
        with build_client(config) as client:
            alice = client.get("/v1/playlist", headers=HEAD).json()
            bob = client.get("/v1/playlist", headers=BOB_HEAD).json()
        assert (alice["playlist"], [b["id"] for b in alice["books"]]) == ("Garmin", ["li_a"])
        assert (bob["playlist"], [b["id"] for b in bob["books"]]) == ("Bob", ["li_x"])

    def test_another_users_book_stays_out_of_reach(self, config):
        prepared_book(config)  # alice's
        with build_client(config) as client:
            assert client.get("/v1/books/li_a/segments", headers=BOB_HEAD).status_code == 409
            assert client.get("/v1/books/li_a/seg/0000.m4a", headers=BOB_HEAD).status_code == 404

    def test_progress_reaches_only_the_pushing_users_server(self, config):
        prepared_book(config)
        prepared_book(config, user="bob")
        alice_sent, bob_sent = {}, {}
        with build_client(config, abs_handler(on_patch=alice_sent.update), bob_handler(on_patch=bob_sent.update)) as client:
            client.post(
                "/v1/progress",
                headers=BOB_HEAD,
                json={"entries": [{"book_id": "li_a", "segment": 1, "offset": 300, "ts": 1_700_000_000}]},
            )
        assert bob_sent["currentTime"] == 1200.0
        assert alice_sent == {}

    def test_a_playlist_releases_only_its_owners_books(self, config):
        alice = prepared_book(config)
        bob = prepared_book(config, user="bob")
        alice.pin("li_a")
        bob.pin("li_a")
        with build_client(config) as client:
            client.get("/v1/playlist", headers=BOB_HEAD)  # li_a is not in Bob's playlist
        assert alice.pinned("li_a")
        assert not bob.pinned("li_a")
