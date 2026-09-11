"""Prepare job: an ABS file is turned into segments for the watch.

The proxy has no access to the ABS media directory, so it must download first.
That is why preparation happens once per book instead of cutting per segment —
otherwise every segment would trigger a full download.

The source file disappears immediately after it is cut, even on error. Peak
usage therefore stays at one source file plus its segments.
"""

from __future__ import annotations

import asyncio
import dataclasses
import logging
import time
from dataclasses import dataclass, field
from enum import Enum
from pathlib import Path

from .abs_client import AbsClient, AbsError
from .cache import Budget, Cache
from .config import Config
from .media import EncodeSpec, MediaError, conforms, cut, probe
from .models import Encoding, Segment
from .parsing import ItemUnusable
from .segmenter import plan_segments

log = logging.getLogger(__name__)

# The download dominates the runtime; stream copy and cover barely matter.
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
    # Shared by every user: CACHE_MAX_BYTES describes the disk, not a person.
    budget: Budget
    # The user's own subdirectory, so two users preparing the same book ID
    # never share a source file.
    work_dir: Path
    # One job at a time: keeps disk usage predictable and ABS calm. Every
    # user's preparer gets the same semaphore, so this holds across users.
    slot: asyncio.Semaphore = field(default_factory=lambda: asyncio.Semaphore(1))

    _states: dict[str, BookState] = field(default_factory=dict)
    _tasks: dict[str, asyncio.Task] = field(default_factory=dict)

    # --- State -------------------------------------------------------------

    def status(self, book_id: str) -> BookState:
        if self.cache.is_ready(book_id):
            manifest = self.cache.load_manifest(book_id) or {}
            return BookState(
                status=Status.READY,
                percent=100,
                segment_count=len(manifest.get("segments") or []),
            )
        state = self._states.get(book_id, BookState())
        if state.status is Status.READY:
            # The manifest is gone, so the book was evicted — possibly by the
            # budget on behalf of another user's job, which never tells this
            # preparer. READY would promise segments that no longer exist.
            return BookState()
        return state

    def _set(self, book_id: str, **changes) -> None:
        state = self._states.setdefault(book_id, BookState())
        for key, value in changes.items():
            setattr(state, key, value)

    # --- Control -----------------------------------------------------------

    def request(self, book_id: str, force: bool = False) -> BookState:
        """Idempotent: a running or finished job is not restarted.

        `force` throws the prepared segments away first, so the job really runs
        again. That is the only way to pick up changed encoder settings: the
        cache outlives the container, and a book that is READY would otherwise
        keep the segments it was cut with forever. A job already in flight is
        left alone — nothing is discarded out from under it.
        """
        self.cache.pin(book_id)
        running = book_id in self._tasks and not self._tasks[book_id].done()
        if force and not running:
            self.cache.discard(book_id)
            self._states.pop(book_id, None)
        state = self.status(book_id)
        if state.status is Status.READY:
            return state
        if running:
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
        # A job cancelled before its first run never reaches the CancelledError
        # branch. Without this cleanup it would stay stuck at "preparing" and the
        # watch would wait for a book nobody is working on anymore.
        for state in self._states.values():
            if state.status is Status.PREPARING:
                state.status = Status.PENDING
                state.percent = 0

    # --- Execution ----------------------------------------------------------

    async def _guarded(self, book_id: str) -> None:
        try:
            async with self.slot:
                await self._prepare(book_id)
        except asyncio.CancelledError:
            self._set(book_id, status=Status.PENDING, percent=0)
            raise
        except (AbsError, MediaError, ItemUnusable, ValueError) as error:
            log.warning("Preparation of %s failed: %s", book_id, error)
            self.cache.discard(book_id)
            self._set(book_id, status=Status.ERROR, error=str(error), percent=0)
        except Exception:  # pragma: no cover - unexpected, but never silent
            log.exception("Preparation of %s with an unexpected error", book_id)
            self.cache.discard(book_id)
            self._set(book_id, status=Status.ERROR, error="Unexpected error, see log")

    async def _encode_for(self, work_file: Path, filename: str) -> EncodeSpec | None:
        """Decide stream copy vs re-encode for one source file.

        None means stream copy. The decision is logged either way: when a book
        will not play on the watch, the first question is what actually went
        onto it.
        """
        if self.config.transcode_mode == "never":
            return None
        spec = EncodeSpec(
            target=self.config.transcode_target,
            bitrate_kbps=self.config.transcode_bitrate_kbps,
        )
        if self.config.transcode_mode == "always":
            log.info("%s: forced re-encode to %s", filename, spec.target)
            return spec
        probed = await probe(work_file)
        if conforms(probed):
            log.info("%s: %s -> stream copy", filename, probed.summary)
            return None
        log.info("%s: %s -> re-encode to %s", filename, probed.summary, spec.target)
        return spec

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
            log.info("%s: 15-minute grid instead of chapters (%s)", item.title, plan.reason)

        largest = max(f.size for f in item.files) if item.files else 0
        needed = item.total_bytes + largest
        if not self.budget.has_room_for(needed):
            self.budget.enforce()
        if not self.budget.has_room_for(needed):
            raise MediaError(
                f"Not enough space in the cache for '{item.title}' "
                f"({needed / 1024**2:.0f} MB needed)"
            )

        by_file: dict[str, list[Segment]] = {}
        for segment in plan.segments:
            by_file.setdefault(segment.source_ino, []).append(segment)

        self.cache.discard(book_id)  # leftovers of an aborted run
        manifest_segments: list[dict] = []
        done_bytes = 0

        for file_index, source in enumerate(item.files):
            segments = by_file.get(source.ino, [])
            if not segments:
                continue
            work_file = self.work_dir / book_id / source.filename
            try:
                def report(written: int, _total: int, base: int = done_bytes) -> None:
                    share = (base + written) / max(1, item.total_bytes)
                    self._set(book_id, percent=int(share * WEIGHT_DOWNLOAD * 100))

                await self.abs_client.download_file(
                    book_id, source.ino, work_file, on_progress=report
                )
                done_bytes += source.size or work_file.stat().st_size

                # The codec name from ABS says nothing about sample rate, so the
                # decision can only be made here, with the file on disk.
                encode = await self._encode_for(work_file, source.filename)
                encoding = source.encoding if encode is None else Encoding(encode.target)

                for position, segment in enumerate(segments):
                    segment = dataclasses.replace(segment, encoding=encoding)
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
                        encode=encode,
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
                # The source file is useless from here on — it must not occupy
                # disk, whether the cut succeeded or not.
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
        log.info("%s prepared: %d segments", item.title, len(manifest_segments))
