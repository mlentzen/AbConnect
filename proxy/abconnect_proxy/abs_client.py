"""HTTP client for one person's Audiobookshelf.

The proxy holds one of these per user, authenticated with that user's API
key. The watch never sees the key: it talks to the proxy, and the proxy
talks here.
"""

from __future__ import annotations

import asyncio
import logging
from collections.abc import Callable
from pathlib import Path

import httpx

from .parsing import ParsedItem, Playlist, find_playlist, parse_item, parse_playlists

log = logging.getLogger(__name__)

CHUNK = 1 << 16


class AbsError(Exception):
    """Audiobookshelf could not be reached, or answered with an error."""


class AbsAuthError(AbsError):
    """The API key was rejected (HTTP 401 or 403)."""


class _TransferBroken(Exception):
    """A download hung or broke off. The httpx error is its __cause__."""


def _describe(error: BaseException | None) -> str:
    """Name an error even when it carries no message, as httpx timeouts do."""
    if error is None:
        return "unknown error"
    text = str(error)
    return f"{type(error).__name__}: {text}" if text else type(error).__name__


class AbsClient:
    """Calls one Audiobookshelf server."""

    def __init__(
        self,
        base_url: str,
        api_key: str,
        *,
        timeout: float = 60.0,
        transport: httpx.AsyncBaseTransport | None = None,
        download_attempts: int = 3,
        retry_delay: float = 2.0,
    ) -> None:
        """Open a client for one Audiobookshelf server.

        Args:
            base_url: That server's origin.
            api_key: Sent as a bearer token on every request.
            timeout: Seconds for a request. The connect timeout stays at 10.
            transport: Replaces the network stack. Tests pass an httpx mock,
                and production leaves it unset.
            download_attempts: How often one file is tried when its transfer
                hangs or breaks off. HTTP errors are not retried.
            retry_delay: Seconds before the second attempt, growing with each
                further one.
        """
        self._download_attempts = max(1, download_attempts)
        self._retry_delay = retry_delay
        self._base_url = base_url.rstrip("/")
        self._client = httpx.AsyncClient(
            base_url=self._base_url,
            headers={"Authorization": f"Bearer {api_key}"},
            timeout=httpx.Timeout(timeout, connect=10.0),
            transport=transport,
            follow_redirects=True,
        )

    async def aclose(self) -> None:
        await self._client.aclose()

    # --- Basics ---------------------------------------------------------------

    async def _get(self, path: str, *, params: dict | None = None) -> httpx.Response:
        try:
            response = await self._client.get(path, params=params)
        except httpx.HTTPError as error:
            raise AbsError(f"Audiobookshelf unreachable: {error}") from error
        if response.status_code in (401, 403):
            raise AbsAuthError("Audiobookshelf rejects the API key")
        if response.status_code >= 400:
            raise AbsError(f"GET {path} -> HTTP {response.status_code}")
        return response

    async def _json(self, path: str, *, params: dict | None = None):
        response = await self._get(path, params=params)
        try:
            return response.json()
        except ValueError as error:
            raise AbsError(f"GET {path} returned no JSON") from error

    async def ping(self) -> None:
        """Check that the server answers and accepts the API key.

        Used by /v1/status, so a bad key is visible before a watch syncs.
        """
        await self._json("/api/libraries")

    # --- Library ----------------------------------------------------------

    async def playlist(self, name: str) -> Playlist | None:
        """Fetch the playlist of this name.

        Audiobookshelf cannot search playlists by name, so the whole list is
        fetched and matched locally. None means the name was not found. It
        does not mean the playlist exists and is empty: a caller that treated
        it that way would drop every cached book.

        Args:
            name: Playlist name in this user's Audiobookshelf.

        Returns:
            The playlist, or None when no playlist has this name.
        """
        payload = await self._json("/api/playlists")
        return find_playlist(parse_playlists(payload), name)

    async def get_item(self, item_id: str) -> ParsedItem:
        """Fetch one library item, with files and chapters included.

        Args:
            item_id: The Audiobookshelf library-item id. The watch uses that
                same value as the book id.

        Returns:
            The item reduced to files, chapters and duration.
        """
        return parse_item(
            await self._json(f"/api/items/{item_id}", params={"expanded": 1})
        )

    # --- Files -------------------------------------------------------------

    async def download_file(
        self,
        item_id: str,
        ino: str,
        destination: Path,
        *,
        on_progress: Callable[[int, int], None] | None = None,
    ) -> int:
        """Download one audio file of an item.

        Args:
            item_id: The Audiobookshelf library-item id.
            ino: Audiobookshelf's id for that file, not the file name.
            destination: Where the finished file is written. A partial file
                is used until the download completes.
            on_progress: Called with bytes written so far and the content
                length. The length is 0 when the server does not send one.
                Omit it to skip progress reports.

        Returns:
            The size of the file written, in bytes.

        Raises:
            AbsAuthError: The API key was rejected.
            AbsError: The transfer failed or returned no data.
        """
        # A transfer can hang or break midway, somewhere between this proxy
        # and Audiobookshelf, even though Audiobookshelf sent everything. The
        # broken connection is dropped by httpx, so a retry uses a new one.
        for attempt in range(1, self._download_attempts + 1):
            try:
                return await self._download_once(
                    item_id, ino, destination, on_progress=on_progress
                )
            except _TransferBroken as broken:
                error = broken.__cause__
                if attempt == self._download_attempts:
                    raise AbsError(
                        f"Download of {ino} aborted after {attempt} attempts: "
                        f"{_describe(error)}"
                    ) from error
                log.warning(
                    "Download of %s broke off (%s), attempt %d of %d, retrying",
                    ino,
                    _describe(error),
                    attempt,
                    self._download_attempts,
                )
                await asyncio.sleep(self._retry_delay * attempt)
        raise AssertionError("unreachable")  # pragma: no cover

    async def _download_once(
        self,
        item_id: str,
        ino: str,
        destination: Path,
        *,
        on_progress: Callable[[int, int], None] | None,
    ) -> int:
        destination.parent.mkdir(parents=True, exist_ok=True)
        partial = destination.with_suffix(destination.suffix + ".part")
        written = 0
        try:
            # One connection per file: on a kept-alive connection, a transfer
            # hung after a few hundred MB, while a fresh one never did.
            async with self._client.stream(
                "GET",
                f"/api/items/{item_id}/file/{ino}/download",
                headers={"Connection": "close"},
            ) as response:
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
        except httpx.TransportError as error:
            partial.unlink(missing_ok=True)
            raise _TransferBroken from error
        except httpx.HTTPError as error:
            partial.unlink(missing_ok=True)
            raise AbsError(f"Download of {ino} aborted: {_describe(error)}") from error
        except BaseException:
            partial.unlink(missing_ok=True)
            raise

        if written == 0:
            partial.unlink(missing_ok=True)
            raise AbsError(f"Download of {ino} returned no data")
        partial.replace(destination)
        return written

    # --- Progress ---------------------------------------------------------

    async def get_progress(self, item_id: str) -> dict | None:
        """Fetch this user's listening position for an item.

        A rejected API key is raised. Any other failure, including the 404
        Audiobookshelf returns before the first listen, comes back as None.

        Args:
            item_id: The Audiobookshelf library-item id.

        Returns:
            The progress JSON, or None when the user has never started the item.

        Raises:
            AbsAuthError: The API key was rejected.
        """
        try:
            payload = await self._json(f"/api/me/progress/{item_id}")
        except AbsAuthError:
            raise
        except AbsError:
            return None  # ABS responds 404 as long as nothing has been listened to
        return payload if isinstance(payload, dict) else None

    async def set_progress(
        self, item_id: str, *, current_time: float, duration: float
    ) -> None:
        """Store a listening position as seconds of absolute book time.

        Audiobookshelf answers 200 even when it drops the update, so the
        stored position is read back and a mismatch is logged.

        Args:
            item_id: The Audiobookshelf library-item id.
            current_time: Where playback is, in seconds of book time.
            duration: Length of the book, in seconds.

        Raises:
            AbsAuthError: The API key was rejected.
            AbsError: The update could not be sent.
        """
        target = round(current_time, 2)
        body = {
            "currentTime": target,
            "duration": round(duration, 2),
            "progress": round(current_time / duration, 6) if duration > 0 else 0.0,
            "isFinished": duration > 0 and current_time >= duration - 5,
        }
        try:
            response = await self._client.patch(
                f"/api/me/progress/{item_id}", json=body
            )
        except httpx.HTTPError as error:
            raise AbsError(
                f"Progress for {item_id} not transmitted: {error}"
            ) from error
        if response.status_code in (401, 403):
            raise AbsAuthError("Audiobookshelf rejects the API key")
        if response.status_code >= 400:
            raise AbsError(
                f"PATCH /api/me/progress/{item_id} -> HTTP {response.status_code}"
            )

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
                item_id,
                target,
                actual,
            )
