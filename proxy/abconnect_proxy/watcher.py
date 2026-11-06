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
        released: Book ids whose cached files were deleted on this pass.
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
class Holdings:
    """Books each playlist still offers the watch.

    A cached book is deleted only once every user has reported a playlist
    and none of those playlists still list it. A user who has not reported
    yet blocks deletion: a refresh that has not happened is not an empty
    playlist. A failed refresh does not call back here, so the previous
    list stands.

    Attributes:
        _wanted: User name mapped to the book ids from the last successful
            read. None means that user has not reported yet.
    """

    _wanted: dict[str, set[str] | None] = field(default_factory=dict)
    _lock: asyncio.Lock = field(default_factory=asyncio.Lock)

    def add(self, user: str) -> None:
        """Register a user who has not reported a playlist yet.

        A user already present is left as they are, so a later registration
        does not wipe a list that was already read.

        Args:
            user: User name from the configuration.
        """
        self._wanted.setdefault(user, None)

    async def remember(self, user: str, book_ids: set[str]) -> None:
        """Publish the books this user is about to keep, before any deletion.

        Called with every candidate on the playlist, including ones that may
        yet be withheld. Peers refreshing at the same time then see the book
        and do not delete a copy this user still lists.

        Args:
            user: Whose playlist was just read.
            book_ids: Book ids on that playlist, capped at what the watch shows.
        """
        async with self._lock:
            self._wanted[user] = set(book_ids)

    async def settle(self, user: str, book_ids: set[str], cached: list[str], release) -> list[str]:
        """Narrow this user's list to the books actually offered, and delete the rest.

        Args:
            user: Whose playlist was just read.
            book_ids: Books the watch will be told about. Withheld books are
                already gone from this set.
            cached: Book ids currently on disk, in the order ``release``
                should see them.
            release: Awaited for each book no playlist still offers.

        Returns:
            The book ids ``release`` was called with. Empty when some user
            has not reported a playlist yet, and empty when every cached
            book is still listed.
        """
        async with self._lock:
            self._wanted[user] = set(book_ids)
            if any(wanted is None for wanted in self._wanted.values()):
                return []
            kept: set[str] = set()
            for wanted in self._wanted.values():
                if wanted:
                    kept.update(wanted)
            stale = [book_id for book_id in cached if book_id not in kept]
            for book_id in stale:
                await release(book_id)
            return stale


@dataclass
class PlaylistWatcher:
    """Keep the shared cache aligned with one playlist in one user's Audiobookshelf.

    Attributes:
        abs_client: That user's Audiobookshelf client.
        cache: The shared segment cache.
        preparer: The shared preparer.
        config: Process configuration. The poll interval comes from here.
        playlist: The playlist's name, not its id.
        user: Whose list this watcher reports. Several watchers share one
            ``holdings`` and each supplies its own name.
        holdings: Book ids every playlist still offers. Shared by all watchers.
    """

    abs_client: AbsClient
    cache: Cache
    preparer: Preparer
    config: Config
    playlist: str
    user: str = ""
    holdings: Holdings = field(default_factory=Holdings)

    _last: PlaylistResult = field(default_factory=PlaylistResult)
    _lock: asyncio.Lock = field(default_factory=asyncio.Lock)

    def __post_init__(self) -> None:
        if not self.user:
            self.user = "sole"
        self.holdings.add(self.user)

    @property
    def last(self) -> PlaylistResult:
        return self._last

    async def refresh(self) -> PlaylistResult:
        """Bring the shared cache in line with this watcher's playlist.

        Books newly on the playlist are prepared and pinned. A cached book
        is deleted only when every user has reported a playlist and none of
        them still list it. When the server cannot be reached, this user's
        previous list is kept, and so are the previous found flag and book
        list. When the name matches no playlist, found is false and nothing
        is released.

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
            # Publish the candidates before preparing any of them, so a peer
            # refreshing now does not delete a book this playlist still lists.
            candidates = [book["id"] for book in playlist.books[:MAX_PLAYLIST_BOOKS]]
            await self.holdings.remember(self.user, set(candidates))
            offered: list[dict] = []
            for book in playlist.books[:MAX_PLAYLIST_BOOKS]:
                book_id = book["id"]
                before = self.preparer.status(book_id).status
                state = await self.preparer.admit(book_id, self.abs_client)
                if state.status is Status.WITHHELD:
                    continue
                offered.append(book)
                if before is Status.PENDING and state.status is Status.PREPARING:
                    result.prepared.append(book_id)
            result.books = offered
            desired = {book["id"] for book in offered}

            async def release(book_id: str) -> None:
                await self.preparer.abandon(book_id)

            result.released = await self.holdings.settle(
                self.user, desired, self.cache.books(), release
            )

            if result.prepared or result.released:
                log.info(
                    "Playlist '%s' updated: %d newly prepared, %d removed",
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
