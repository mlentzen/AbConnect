"""Audiobookshelf access.

The API key lives only here. The watch never sees this layer — it only gets
what api.py shapes out of it.
"""

from __future__ import annotations

import asyncio
import logging
import time
from collections.abc import Callable
from pathlib import Path

import httpx

from .parsing import (
    ParsedItem,
    Playlist,
    find_playlist,
    parse_book_libraries,
    parse_item,
    parse_listing,
    parse_playlists,
)

log = logging.getLogger(__name__)

LISTING_TTL_SECONDS = 300
CHUNK = 1 << 16


class AbsError(Exception):
    pass


class AbsAuthError(AbsError):
    pass


class AbsClient:
    def __init__(
        self,
        base_url: str,
        api_key: str,
        *,
        timeout: float = 60.0,
        transport: httpx.AsyncBaseTransport | None = None,
    ) -> None:
        self._base_url = base_url.rstrip("/")
        self._client = httpx.AsyncClient(
            base_url=self._base_url,
            headers={"Authorization": f"Bearer {api_key}"},
            timeout=httpx.Timeout(timeout, connect=10.0),
            transport=transport,
            follow_redirects=True,
        )
        self._listing: tuple[float, list[dict]] | None = None
        self._listing_lock = asyncio.Lock()

    async def aclose(self) -> None:
        await self._client.aclose()

    # --- Basics ---------------------------------------------------------------

    async def _get(self, path: str, **kwargs) -> httpx.Response:
        try:
            response = await self._client.get(path, **kwargs)
        except httpx.HTTPError as error:
            raise AbsError(f"Audiobookshelf unreachable: {error}") from error
        if response.status_code in (401, 403):
            raise AbsAuthError("Audiobookshelf rejects the API key")
        if response.status_code >= 400:
            raise AbsError(f"GET {path} -> HTTP {response.status_code}")
        return response

    async def _json(self, path: str, **kwargs):
        response = await self._get(path, **kwargs)
        try:
            return response.json()
        except ValueError as error:
            raise AbsError(f"GET {path} returned no JSON") from error

    async def ping(self) -> None:
        """For /health: checks reachability *and* the key in one go."""
        await self._json("/api/libraries")

    # --- Library ----------------------------------------------------------

    async def library_ids(self) -> list[str]:
        return parse_book_libraries(await self._json("/api/libraries"))

    async def all_books(self, *, force: bool = False) -> list[dict]:
        """Complete book list, briefly cached.

        Fetching everything at once and paging through it in memory is much
        simpler than mapping a watch page number onto ABS offsets across
        multiple libraries. For a few thousand books this is a few hundred
        kilobytes.
        """
        async with self._listing_lock:
            now = time.monotonic()
            if not force and self._listing and now - self._listing[0] < LISTING_TTL_SECONDS:
                return self._listing[1]

            books: list[dict] = []
            for library_id in await self.library_ids():
                payload = await self._json(
                    f"/api/libraries/{library_id}/items",
                    params={"limit": 0, "sort": "media.metadata.title", "minified": 1},
                )
                page, _ = parse_listing(payload)
                books.extend(page)

            books.sort(key=lambda b: b["title"].casefold())
            self._listing = (now, books)
            return books

    async def playlist(self, name: str) -> Playlist | None:
        """Fetch a playlist by its name.

        ABS cannot search playlists by name, so the list is fetched and
        resolved locally. If none has this name, None is returned — and the
        caller must *not* infer an empty playlist from that.
        """
        payload = await self._json("/api/playlists")
        return find_playlist(parse_playlists(payload), name)

    async def get_item(self, item_id: str) -> ParsedItem:
        return parse_item(await self._json(f"/api/items/{item_id}", params={"expanded": 1}))

    # --- Files -------------------------------------------------------------

    async def download_file(
        self,
        item_id: str,
        ino: str,
        destination: Path,
        *,
        on_progress: Callable[[int, int], None] | None = None,
    ) -> int:
        """Downloads an audio file to `destination`. Returns its size."""
        destination.parent.mkdir(parents=True, exist_ok=True)
        partial = destination.with_suffix(destination.suffix + ".part")
        written = 0
        try:
            async with self._client.stream("GET", f"/api/items/{item_id}/file/{ino}/download") as response:
                if response.status_code in (401, 403):
                    raise AbsAuthError("Audiobookshelf rejects the API key")
                if response.status_code >= 400:
                    raise AbsError(f"Download of {ino} -> HTTP {response.status_code}")
                total = int(response.headers.get("content-length") or 0)
                with partial.open("wb") as sink:
                    async for chunk in response.aiter_bytes(CHUNK):
                        sink.write(chunk)
                        written += len(chunk)
                        if on_progress:
                            on_progress(written, total)
        except httpx.HTTPError as error:
            partial.unlink(missing_ok=True)
            raise AbsError(f"Download of {ino} aborted: {error}") from error
        except BaseException:
            partial.unlink(missing_ok=True)
            raise

        if written == 0:
            partial.unlink(missing_ok=True)
            raise AbsError(f"Download of {ino} returned no data")
        partial.replace(destination)
        return written

    async def get_cover(self, item_id: str, width: int = 300) -> bytes | None:
        try:
            response = await self._get(
                f"/api/items/{item_id}/cover", params={"width": width, "format": "jpeg"}
            )
        except AbsError as error:
            log.info("No cover for %s: %s", item_id, error)
            return None
        return response.content or None

    # --- Progress ---------------------------------------------------------

    async def get_progress(self, item_id: str) -> dict | None:
        try:
            payload = await self._json(f"/api/me/progress/{item_id}")
        except AbsAuthError:
            raise
        except AbsError:
            return None  # ABS responds 404 as long as nothing has been listened to
        return payload if isinstance(payload, dict) else None

    async def set_progress(self, item_id: str, *, current_time: float, duration: float) -> None:
        target = round(current_time, 2)
        body = {
            "currentTime": target,
            "duration": round(duration, 2),
            "progress": round(current_time / duration, 6) if duration > 0 else 0.0,
            "isFinished": duration > 0 and current_time >= duration - 5,
        }
        try:
            response = await self._client.patch(f"/api/me/progress/{item_id}", json=body)
        except httpx.HTTPError as error:
            raise AbsError(f"Progress for {item_id} not transmitted: {error}") from error
        if response.status_code in (401, 403):
            raise AbsAuthError("Audiobookshelf rejects the API key")
        if response.status_code >= 400:
            raise AbsError(f"PATCH /api/me/progress/{item_id} -> HTTP {response.status_code}")

        # ABS answers 200 even when it quietly drops the update (stale session,
        # a newer server-side position). Read it straight back so a no-op push
        # is visible in the log instead of looking like a success.
        stored = await self.get_progress(item_id)
        actual = float((stored or {}).get("currentTime") or 0.0)
        if stored is None:
            log.warning("Progress readback for %s: ABS still reports nothing", item_id)
        elif abs(actual - target) <= 1.0:
            log.info("Progress readback for %s: ABS confirms %.1fs", item_id, actual)
        else:
            log.warning(
                "Progress readback for %s: pushed %.1fs but ABS holds %.1fs",
                item_id, target, actual,
            )
