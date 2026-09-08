import httpx
import pytest

from abconnect_proxy.abs_client import AbsAuthError, AbsClient, AbsError

pytestmark = pytest.mark.anyio

LIBRARIES = {"libraries": [{"id": "lib1", "mediaType": "book"}, {"id": "pod", "mediaType": "podcast"}]}


def client_for(handler) -> AbsClient:
    return AbsClient("https://abs.example", "key-123", transport=httpx.MockTransport(handler))


async def test_sends_the_api_key_as_bearer():
    seen = {}

    def handler(request):
        seen["auth"] = request.headers.get("authorization")
        return httpx.Response(200, json=LIBRARIES)

    await client_for(handler).ping()
    assert seen["auth"] == "Bearer key-123"


async def test_ping_reports_a_rejected_key_distinctly():
    with pytest.raises(AbsAuthError):
        await client_for(lambda r: httpx.Response(401, json={})).ping()


async def test_ping_reports_an_unreachable_server():
    def handler(request):
        raise httpx.ConnectError("no route", request=request)

    with pytest.raises(AbsError, match="unreachable"):
        await client_for(handler).ping()


async def test_all_books_skips_podcast_libraries_and_sorts_by_title():
    calls = []

    def handler(request):
        if request.url.path == "/api/libraries":
            return httpx.Response(200, json=LIBRARIES)
        calls.append(request.url.path)
        return httpx.Response(
            200,
            json={
                "total": 2,
                "results": [
                    {"id": "b", "media": {"metadata": {"title": "Second"}}},
                    {"id": "a", "media": {"metadata": {"title": "First"}}},
                ],
            },
        )

    books = await client_for(handler).all_books()

    assert calls == ["/api/libraries/lib1/items"]
    assert [b["title"] for b in books] == ["First", "Second"]


async def test_all_books_is_cached_between_calls():
    hits = []

    def handler(request):
        hits.append(request.url.path)
        if request.url.path == "/api/libraries":
            return httpx.Response(200, json=LIBRARIES)
        return httpx.Response(200, json={"results": []})

    abs_client = client_for(handler)
    await abs_client.all_books()
    await abs_client.all_books()
    assert hits.count("/api/libraries") == 1

    await abs_client.all_books(force=True)
    assert hits.count("/api/libraries") == 2


class TestDownload:
    async def test_writes_the_file_and_reports_progress(self, tmp_path):
        payload = b"0123456789" * 20_000

        def handler(request):
            assert request.url.path == "/api/items/li_1/file/9001/download"
            return httpx.Response(200, content=payload)

        seen = []
        size = await client_for(handler).download_file(
            "li_1", "9001", tmp_path / "book.m4b", on_progress=lambda done, total: seen.append(done)
        )

        assert size == len(payload)
        assert (tmp_path / "book.m4b").read_bytes() == payload
        assert seen and seen[-1] == len(payload)

    async def test_leaves_no_partial_file_behind_when_the_transfer_dies(self, tmp_path):
        def handler(request):
            raise httpx.ReadError("connection lost", request=request)

        with pytest.raises(AbsError):
            await client_for(handler).download_file("li_1", "9001", tmp_path / "book.m4b")

        assert list(tmp_path.iterdir()) == []

    async def test_rejects_an_empty_response(self, tmp_path):
        with pytest.raises(AbsError, match="no data"):
            await client_for(lambda r: httpx.Response(200, content=b"")).download_file(
                "li_1", "9001", tmp_path / "book.m4b"
            )


class TestProgress:
    async def test_missing_progress_is_not_an_error(self):
        assert await client_for(lambda r: httpx.Response(404, json={})).get_progress("li_1") is None

    async def test_patch_computes_ratio_and_finished_flag(self):
        sent = {}

        def handler(request):
            import json

            sent.update(json.loads(request.content))
            return httpx.Response(200, json={})

        await client_for(handler).set_progress("li_1", current_time=1800, duration=3600)
        assert sent["progress"] == 0.5
        assert sent["isFinished"] is False

        await client_for(handler).set_progress("li_1", current_time=3599, duration=3600)
        assert sent["isFinished"] is True

    async def test_patch_surfaces_a_rejected_key(self):
        with pytest.raises(AbsAuthError):
            await client_for(lambda r: httpx.Response(403, json={})).set_progress(
                "li_1", current_time=1, duration=2
            )
