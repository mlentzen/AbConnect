from __future__ import annotations

import asyncio
import logging
from dataclasses import dataclass, field

from .abs_client import AbsClient, AbsError
from .cache import Cache
from .config import Config
from .preparer import Preparer, Status

log = logging.getLogger(__name__)

#: The watch mirrors this prefix of the playlist. Connect IQ aborts a larger
#: JSON response, and more books than this do not belong on the device.
MAX_PLAYLIST_BOOKS = 50


@dataclass
class PlaylistResult:
    """Outcome of one pass over the playlist.

    Attributes:
        found: True when the named playlist exists.
        books: What the watch should list: id, title, author and duration.
            At most ``MAX_PLAYLIST_BOOKS``, in playlist order.
        total: How many books the playlist holds, including those past the cap.
        prepared: Book ids this pass started preparing.
        released: Book ids this pass let go of.
        error: Set when the server could not be asked, or the playlist name
            does not exist. Empty on success.
    """

    found: bool = False
    books: list[dict] = field(default_factory=list)
    total: int = 0
    prepared: list[str] = field(default_factory=list)
    released: list[str] = field(default_factory=list)
    error: str = ""


@dataclass
class PlaylistWatcher:
    """Keep one user's cache aligned with one playlist in their Audiobookshelf.

    Attributes:
        abs_client: That user's Audiobookshelf client.
        cache: That user's segment cache.
        preparer: That user's preparer.
        config: Process configuration. The poll interval comes from here.
        playlist: The playlist's name, not its id.
    """

    abs_client: AbsClient
    cache: Cache
    preparer: Preparer
    config: Config
    playlist: str

    _last: PlaylistResult = field(default_factory=PlaylistResult)
    _lock: asyncio.Lock = field(default_factory=asyncio.Lock)

    @property
    def last(self) -> PlaylistResult:
        return self._last

    async def refresh(self) -> PlaylistResult:
        """Bring the cache in line with this watcher's playlist.

        Books newly on the playlist are prepared and pinned. A pinned book
        that has left the playlist is released, so its files stay until the
        TTL. When the server cannot be reached, the previous found flag and
        book list are kept. When the name matches no playlist, found is false
        and the cache is left as it is.

        Returns:
            The outcome of this pass.
        """
        async with self._lock:
            result = PlaylistResult()
            try:
                playlist = await self.abs_client.playlist(self.playlist)
            except AbsError as error:
                # No access means "unknown", not "empty".
                result.error = str(error)
                result.found = self._last.found
                result.books = self._last.books
                result.total = self._last.total
                log.warning("Playlist '%s' not retrievable: %s", self.playlist, error)
                self._last = result
                return result

            if playlist is None:
                result.error = (
                    f"Playlist '{self.playlist}' does not exist in Audiobookshelf"
                )
                log.warning("%s. Cache stays untouched", result.error)
                self._last = result
                return result

            result.found = True
            result.total = len(playlist.books)
            offered: list[dict] = []
            for book in playlist.books[:MAX_PLAYLIST_BOOKS]:
                book_id = book["id"]
                before = self.preparer.status(book_id).status
                state = await self.preparer.admit(book_id)
                if state.status is Status.WITHHELD:
                    continue
                offered.append(book)
                if before is Status.PENDING and state.status is Status.PREPARING:
                    result.prepared.append(book_id)
            result.books = offered
            desired = {book["id"] for book in offered}

            for book_id in self.cache.books():
                if book_id not in desired and self.cache.pinned(book_id):
                    self.cache.release(book_id)
                    result.released.append(book_id)

            if result.prepared or result.released:
                log.info(
                    "Playlist '%s' updated: %d newly prepared, %d released",
                    self.playlist,
                    len(result.prepared),
                    len(result.released),
                )
            self._last = result
            return result

    async def run_forever(self) -> None:
        """Refresh, wait playlist_poll_seconds, and repeat.

        A failure is logged and the loop continues. Cancelling the task
        stops it.
        """
        while True:
            try:
                await self.refresh()
                await asyncio.sleep(self.config.playlist_poll_seconds)
            except asyncio.CancelledError:
                raise
            except Exception:
                log.exception("Playlist refresh failed")
                await asyncio.sleep(self.config.playlist_poll_seconds)
