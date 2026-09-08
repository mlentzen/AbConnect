"""Prepare-Job: aus einer ABS-Datei werden Segmente für die Uhr.

Der Proxy hat keinen Zugriff auf das ABS-Medienverzeichnis, muss also erst
herunterladen. Deshalb wird pro Buch einmal vorbereitet und nicht pro Segment
geschnitten — sonst löste jedes Segment einen Vollabzug aus.

Die Quelldatei verschwindet unmittelbar nach ihrem Schnitt, auch im Fehlerfall.
Der Spitzenbedarf bleibt damit eine Quelldatei plus deren Segmente.
"""

from __future__ import annotations

import asyncio
import logging
import time
from dataclasses import dataclass, field
from enum import Enum

from .abs_client import AbsClient, AbsError
from .cache import Cache
from .config import Config
from .media import MediaError, cut
from .models import Segment
from .parsing import ItemUnusable
from .segmenter import plan_segments

log = logging.getLogger(__name__)

# Der Download dominiert die Laufzeit; Stream-Copy und Cover fallen kaum ins Gewicht.
WEIGHT_DOWNLOAD = 0.65
WEIGHT_CUT = 0.30
WEIGHT_COVER = 0.05


class Status(str, Enum):
    PENDING = "pending"
    PREPARING = "preparing"
    READY = "ready"
    ERROR = "error"


@dataclass
class BookState:
    status: Status = Status.PENDING
    percent: int = 0
    error: str = ""
    segment_count: int = 0


@dataclass
class Preparer:
    abs_client: AbsClient
    cache: Cache
    config: Config

    _states: dict[str, BookState] = field(default_factory=dict)
    _tasks: dict[str, asyncio.Task] = field(default_factory=dict)
    # Ein Job zur Zeit: hält den Plattenbedarf vorhersagbar und ABS ruhig.
    _slot: asyncio.Semaphore = field(default_factory=lambda: asyncio.Semaphore(1))

    # --- Zustand -------------------------------------------------------------

    def status(self, book_id: str) -> BookState:
        if self.cache.is_ready(book_id):
            manifest = self.cache.load_manifest(book_id) or {}
            return BookState(
                status=Status.READY,
                percent=100,
                segment_count=len(manifest.get("segments") or []),
            )
        return self._states.get(book_id, BookState())

    def _set(self, book_id: str, **changes) -> None:
        state = self._states.setdefault(book_id, BookState())
        for key, value in changes.items():
            setattr(state, key, value)

    # --- Steuerung -----------------------------------------------------------

    def request(self, book_id: str) -> BookState:
        """Idempotent: ein laufender oder fertiger Job wird nicht neu gestartet."""
        self.cache.pin(book_id)
        state = self.status(book_id)
        if state.status is Status.READY:
            return state
        if book_id in self._tasks and not self._tasks[book_id].done():
            return state

        self._set(book_id, status=Status.PREPARING, percent=0, error="")
        task = asyncio.create_task(self._guarded(book_id), name=f"prepare:{book_id}")
        self._tasks[book_id] = task
        task.add_done_callback(lambda t: self._tasks.pop(book_id, None))
        return self.status(book_id)

    def forget(self, book_id: str) -> None:
        self._states.pop(book_id, None)

    async def shutdown(self) -> None:
        for task in list(self._tasks.values()):
            task.cancel()
        if self._tasks:
            await asyncio.gather(*self._tasks.values(), return_exceptions=True)
        # Ein Job, der vor seinem ersten Lauf abgebrochen wurde, kommt nie in den
        # CancelledError-Zweig. Ohne diesen Nachlauf bliebe er auf "preparing"
        # stehen und die Uhr wartete auf ein Buch, an dem niemand mehr arbeitet.
        for state in self._states.values():
            if state.status is Status.PREPARING:
                state.status = Status.PENDING
                state.percent = 0

    # --- Ausführung ----------------------------------------------------------

    async def _guarded(self, book_id: str) -> None:
        try:
            async with self._slot:
                await self._prepare(book_id)
        except asyncio.CancelledError:
            self._set(book_id, status=Status.PENDING, percent=0)
            raise
        except (AbsError, MediaError, ItemUnusable, ValueError) as error:
            log.warning("Vorbereitung von %s gescheitert: %s", book_id, error)
            self.cache.discard(book_id)
            self._set(book_id, status=Status.ERROR, error=str(error), percent=0)
        except Exception:  # pragma: no cover - unerwartet, aber nie stillschweigend
            log.exception("Vorbereitung von %s mit unerwartetem Fehler", book_id)
            self.cache.discard(book_id)
            self._set(book_id, status=Status.ERROR, error="Unerwarteter Fehler, siehe Log")

    async def _prepare(self, book_id: str) -> None:
        item = await self.abs_client.get_item(book_id)
        plan = plan_segments(
            item.files,
            item.chapters,
            target_seconds=self.config.segment_target_seconds,
            min_seconds=self.config.segment_min_seconds,
            max_seconds=self.config.segment_max_seconds,
        )
        if plan.used_fallback:
            log.info("%s: 15-Minuten-Raster statt Kapiteln (%s)", item.title, plan.reason)

        largest = max(f.size for f in item.files) if item.files else 0
        if not self.cache.has_room_for(item.total_bytes + largest, self.config.cache_max_bytes):
            self.cache.enforce_budget(self.config.cache_max_bytes)
        if not self.cache.has_room_for(item.total_bytes + largest, self.config.cache_max_bytes):
            raise MediaError(
                f"Zu wenig Platz im Cache für '{item.title}' "
                f"({(item.total_bytes + largest) / 1024**2:.0f} MB benötigt)"
            )

        by_file: dict[str, list[Segment]] = {}
        for segment in plan.segments:
            by_file.setdefault(segment.source_ino, []).append(segment)

        self.cache.discard(book_id)  # Reste eines abgebrochenen Laufs
        manifest_segments: list[dict] = []
        done_bytes = 0

        for file_index, source in enumerate(item.files):
            segments = by_file.get(source.ino, [])
            if not segments:
                continue
            work_file = self.config.work_dir / book_id / source.filename
            try:
                def report(written: int, _total: int, base: int = done_bytes) -> None:
                    share = (base + written) / max(1, item.total_bytes)
                    self._set(book_id, percent=int(share * WEIGHT_DOWNLOAD * 100))

                await self.abs_client.download_file(
                    book_id, source.ino, work_file, on_progress=report
                )
                done_bytes += source.size or work_file.stat().st_size

                for position, segment in enumerate(segments):
                    destination = self.cache.segment_path(book_id, segment.filename)
                    size = await cut(
                        work_file,
                        destination,
                        start=segment.source_start,
                        duration=segment.duration,
                        title=segment.title,
                        artist=item.author,
                        album=item.title,
                        track=segment.index + 1,
                    )
                    manifest_segments.append(
                        {
                            "index": segment.index,
                            "title": segment.title,
                            "duration": round(segment.duration, 3),
                            "book_start": segment.book_start,
                            "bytes": size,
                            "encoding": segment.encoding.value,
                            "file": segment.filename,
                        }
                    )
                    cut_share = (position + 1) / len(segments)
                    file_share = (file_index + cut_share) / len(item.files)
                    self._set(
                        book_id,
                        percent=int((WEIGHT_DOWNLOAD + file_share * WEIGHT_CUT) * 100),
                    )
            finally:
                # Die Quelldatei ist ab hier nutzlos — sie darf keine Platte belegen,
                # egal ob der Schnitt geklappt hat oder nicht.
                work_file.unlink(missing_ok=True)
                parent = work_file.parent
                if parent.exists() and not any(parent.iterdir()):
                    parent.rmdir()

        if item.has_cover:
            cover = await self.abs_client.get_cover(book_id, width=300)
            if cover:
                self.cache.cover_path(book_id).write_bytes(cover)
        self._set(book_id, percent=int((WEIGHT_DOWNLOAD + WEIGHT_CUT + WEIGHT_COVER) * 100))

        manifest_segments.sort(key=lambda s: s["index"])
        self.cache.store_manifest(
            book_id,
            {
                "book_id": book_id,
                "title": item.title,
                "author": item.author,
                "duration": round(plan.total_duration, 3),
                "chapter_source": plan.chapter_source,
                "reason": plan.reason,
                "cover": self.cache.cover_path(book_id).exists(),
                "prepared_at": time.time(),
                "segments": manifest_segments,
            },
        )
        self.cache.touch(book_id)
        self._set(book_id, status=Status.READY, percent=100, segment_count=len(manifest_segments))
        log.info("%s vorbereitet: %d Segmente", item.title, len(manifest_segments))
