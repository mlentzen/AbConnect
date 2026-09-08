"""Abgleich der ABS-Playlist mit dem Cache.

Die Playlist ist die Sollvorgabe: was darin liegt, wird vorbereitet; was
verschwindet, wird freigegeben. Der Abgleich läuft im Hintergrund, damit ein
neu hinzugefügtes Buch schon geschnitten bereitliegt, bevor die Uhr das nächste
Mal synchronisiert.

Wichtigste Regel: Eine Playlist, die nicht gefunden wird, ist kein Grund, den
Cache zu leeren. Ein Tippfehler im Namen oder ein kurz nicht erreichbares ABS
würde sonst die Uhr leerräumen.
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
                # Kein Zugriff heißt "unbekannt", nicht "leer".
                result.error = str(error)
                result.found = self._last.found
                result.books = self._last.books
                log.warning("Playlist nicht abrufbar: %s", error)
                self._last = result
                return result

            if playlist is None:
                result.error = f"Playlist '{self.config.abs_playlist}' existiert in Audiobookshelf nicht"
                log.warning("%s — Cache bleibt unangetastet", result.error)
                self._last = result
                return result

            result.found = True
            result.books = playlist.books
            desired = set(playlist.book_ids)

            for book_id in playlist.book_ids:
                state = self.preparer.status(book_id)
                if state.status is Status.READY:
                    # Ein wieder aufgenommenes Buch muss erneut angepinnt werden,
                    # sonst verdrängt es die Notbremse trotz Playlist-Zugehörigkeit.
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
                    "Playlist abgeglichen: %d neu vorbereitet, %d freigegeben",
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
            except Exception:  # pragma: no cover - der Abgleich darf nie den Prozess reißen
                log.exception("Playlist-Abgleich gescheitert")
                await asyncio.sleep(self.config.playlist_poll_seconds)
