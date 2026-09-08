"""Reconciliation of the ABS playlist with the cache.

The playlist is the target: whatever is in it gets prepared; whatever
disappears gets released. Reconciliation runs in the background so a newly
added book is already segmented and ready before the watch syncs the next time.

Most important rule: a playlist that is not found is no reason to empty the
cache. A typo in the name or a briefly unreachable ABS would otherwise wipe
the watch.
"""

from __future__ import annotations

import asyncio
import logging
import time
from dataclasses import dataclass, field

from .abs_client import AbsClient, AbsError
from .cache import Cache
from .config import Config
from .preparer import Preparer, Status

log = logging.getLogger(__name__)


@dataclass
class ReconcileResult:
    found: bool = False
    books: list[dict] = field(default_factory=list)
    prepared: list[str] = field(default_factory=list)
    released: list[str] = field(default_factory=list)
    error: str = ""
    checked_at: float = 0.0


@dataclass
class PlaylistReconciler:
    abs_client: AbsClient
    cache: Cache
    preparer: Preparer
    config: Config

    _last: ReconcileResult = field(default_factory=ReconcileResult)
    _lock: asyncio.Lock = field(default_factory=asyncio.Lock)

    @property
    def last(self) -> ReconcileResult:
        return self._last

    async def reconcile(self) -> ReconcileResult:
        async with self._lock:
            result = ReconcileResult(checked_at=time.time())
            try:
                playlist = await self.abs_client.playlist(self.config.abs_playlist)
            except AbsError as error:
                # No access means "unknown", not "empty".
                result.error = str(error)
                result.found = self._last.found
                result.books = self._last.books
                log.warning("Playlist not retrievable: %s", error)
                self._last = result
                return result

            if playlist is None:
                result.error = f"Playlist '{self.config.abs_playlist}' does not exist in Audiobookshelf"
                log.warning("%s — cache stays untouched", result.error)
                self._last = result
                return result

            result.found = True
            result.books = playlist.books
            desired = set(playlist.book_ids)

            for book_id in playlist.book_ids:
                state = self.preparer.status(book_id)
                if state.status is Status.READY:
                    # A re-added book must be pinned again, otherwise the
                    # emergency brake evicts it despite being in the playlist.
                    self.cache.pin(book_id)
                elif state.status is Status.PENDING:
                    self.preparer.request(book_id)
                    result.prepared.append(book_id)

            for book_id in self.cache.books():
                if book_id not in desired and self.cache.pinned(book_id):
                    self.cache.release(book_id)
                    result.released.append(book_id)

            if result.prepared or result.released:
                log.info(
                    "Playlist reconciled: %d newly prepared, %d released",
                    len(result.prepared),
                    len(result.released),
                )
            self._last = result
            return result

    async def run_forever(self) -> None:
        while True:
            try:
                await self.reconcile()
                await asyncio.sleep(self.config.playlist_poll_seconds)
            except asyncio.CancelledError:
                raise
            except Exception:  # pragma: no cover - reconciliation must never take down the process
                log.exception("Playlist reconciliation failed")
                await asyncio.sleep(self.config.playlist_poll_seconds)
