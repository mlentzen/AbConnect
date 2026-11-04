"""Prepare job: an Audiobookshelf book is turned into mp3 segments for the watch.

The proxy has no access to the Audiobookshelf media directory, so it must download first.
That is why preparation happens once per book instead of cutting per segment.
Otherwise every segment would trigger a full download.

The source file disappears immediately after it is cut, even on error. Peak
usage therefore stays at one source file plus its segments.
"""

from __future__ import annotations

import asyncio
import logging
import time
from dataclasses import dataclass, field
from enum import Enum
from pathlib import Path

from .abs_client import AbsClient, AbsError
from .cache import Budget, Cache
from .config import Config
from .media import MediaError, cut
from .models import Segment
from .parsing import ItemUnusable, ParsedItem
from .segmenter import NotForWatch, plan_segments

log = logging.getLogger(__name__)

WEIGHT_DOWNLOAD = 0.65
WEIGHT_CUT = 0.35


class Status(str, Enum):
    """Preparation state the watch is told.

    Attributes:
        PENDING: Not started, or the segments were removed.
        PREPARING: A job is running.
        READY: The segments are on disk.
        ERROR: The last attempt failed.
        WITHHELD: The book is not offered to the watch.
    """

    PENDING = "pending"
    PREPARING = "preparing"
    READY = "ready"
    ERROR = "error"
    WITHHELD = "withheld"


@dataclass
class BookState:
    """Where preparation of one book stands, in memory.

    A ready book is also recorded by its manifest on disk. This object is
    only the live job.

    Attributes:
        status: pending, preparing, ready or error.
        percent: 0 to 100 while preparing.
        error: Set together with status error. Empty otherwise.
        segment_count: Filled once the book is ready.
    """

    status: Status = Status.PENDING
    percent: int = 0
    error: str = ""
    segment_count: int = 0


@dataclass
class Preparer:
    """Downloads one user's books and cuts them into segments.

    Attributes:
        abs_client: That user's Audiobookshelf client.
        cache: That user's segment cache.
        config: Process configuration. The mp3 bitrate comes from here.
        budget: Disk limit shared by every user.
        work_dir: This user's scratch directory. The downloaded source file
            is deleted as soon as it has been cut.
        slot: Semaphore every preparer waits on, so only one book is
            prepared at a time across the whole process.
    """

    abs_client: AbsClient
    cache: Cache
    config: Config
    # Shared by every user: CACHE_MAX_BYTES describes the disk, not a person.
    budget: Budget
    # The user's own subdirectory, so two users preparing the same book ID
    # never share a source file.
    work_dir: Path
    slot: asyncio.Semaphore = field(default_factory=lambda: asyncio.Semaphore(1))

    _states: dict[str, BookState] = field(default_factory=dict)
    _tasks: dict[str, asyncio.Task] = field(default_factory=dict)
    # Item already fetched by admit(), so the job does not fetch it again.
    _staged: dict[str, ParsedItem] = field(default_factory=dict)

    # --- State -------------------------------------------------------------

    def status(self, book_id: str) -> BookState:
        """Report where this book stands.

        A manifest on disk means ready, even after a restart. Ready in
        memory with no manifest means the book was deleted out from under
        this preparer, so the report falls back to pending.

        Args:
            book_id: Audiobookshelf library-item id.

        Returns:
            The live state, or a ready state built from the manifest.
        """
        if self.cache.is_ready(book_id):
            manifest = self.cache.load_manifest(book_id) or {}
            return BookState(
                status=Status.READY,
                percent=100,
                segment_count=len(manifest.get("segments") or []),
            )
        state = self._states.get(book_id, BookState())
        if state.status is Status.READY:
            # The manifest is gone, so the book was evicted, possibly by the
            # budget on behalf of another user's job, which never tells this
            # preparer. READY would promise segments that no longer exist.
            return BookState()
        return state

    def _set(
        self,
        book_id: str,
        *,
        status: Status | None = None,
        percent: int | None = None,
        error: str | None = None,
        segment_count: int | None = None,
    ) -> None:
        state = self._states.setdefault(book_id, BookState())
        if status is not None:
            state.status = status
        if percent is not None:
            state.percent = percent
        if error is not None:
            state.error = error
        if segment_count is not None:
            state.segment_count = segment_count

    # --- Control -----------------------------------------------------------

    def _withhold(self, book_id: str, title: str, error: BaseException) -> None:
        log.warning("%s (%s): not offered to the watch: %s", title, book_id, error)
        if self.cache.pinned(book_id):
            self.cache.release(book_id)
        self._set(book_id, status=Status.WITHHELD, error=str(error), percent=0)

    async def admit(self, book_id: str) -> BookState:
        """Decide whether the watch may see this book, and start preparation.

        A chapter-less m4b, or a book that is neither mp3 files nor an m4b,
        is withheld: the caller leaves it out of the playlist. A ready book
        is pinned. An errored book is left alone.

        Args:
            book_id: Audiobookshelf library-item id.

        Returns:
            The state after the decision. Withheld means the watch must not
            be told about the book.
        """
        running = book_id in self._tasks and not self._tasks[book_id].done()
        state = self.status(book_id)
        if state.status is Status.READY or running:
            if state.status is Status.READY:
                self.cache.pin(book_id)
            return state
        if state.status is Status.ERROR:
            return state

        try:
            item = await self.abs_client.get_item(book_id)
        except ItemUnusable as error:
            self._withhold(book_id, book_id, error)
            return self.status(book_id)
        except AbsError as error:
            log.warning("Preparation of %s failed: %s", book_id, error)
            self._set(book_id, status=Status.ERROR, error=str(error), percent=0)
            return self.status(book_id)

        try:
            plan_segments(item.files, item.chapters)
        except NotForWatch as error:
            self._withhold(book_id, item.title, error)
            return self.status(book_id)

        self._staged[book_id] = item
        return self.request(book_id)

    def request(self, book_id: str) -> BookState:
        """Ask for the book to be prepared.

        A running or finished job is not restarted.

        Args:
            book_id: Audiobookshelf library-item id.

        Returns:
            The state after the request. A new job reports preparing.
        """
        self.cache.pin(book_id)
        running = book_id in self._tasks and not self._tasks[book_id].done()
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
        """Drop the in-memory status.

        The files, if any remain, belong to the cache.

        Args:
            book_id: Audiobookshelf library-item id.
        """
        self._states.pop(book_id, None)

    async def shutdown(self) -> None:
        """Cancel running jobs and put those books back to pending.

        A cancelled job is not left on "preparing", or the watch would wait
        for a book nobody is working on anymore.
        """
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
        except (AbsError, MediaError, ValueError) as error:
            log.warning("Preparation of %s failed: %s", book_id, error)
            self.cache.discard(book_id)
            self._set(book_id, status=Status.ERROR, error=str(error), percent=0)
        except Exception:  # pragma: no cover - unexpected, but never silent
            log.exception("Preparation of %s with an unexpected error", book_id)
            self.cache.discard(book_id)
            self._set(book_id, status=Status.ERROR, error="Unexpected error, see log")

    async def _prepare(self, book_id: str) -> None:
        item = self._staged.pop(book_id, None)
        if item is None:
            try:
                item = await self.abs_client.get_item(book_id)
            except ItemUnusable as error:
                self._withhold(book_id, book_id, error)
                return
        try:
            plan = plan_segments(item.files, item.chapters)
        except NotForWatch as error:
            self._withhold(book_id, item.title, error)
            return

        # mp3 files are copied. An m4b chapter is encoded to mp3.
        bitrate = (
            self.config.transcode_bitrate_kbps
            if plan.chapter_source == "chapters"
            else None
        )
        if bitrate is None:
            log.info(
                "%s: copying %d mp3 files unchanged", item.title, len(plan.segments)
            )
        else:
            log.info("%s: m4b, %d segments to cut", item.title, len(plan.segments))

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

        self.cache.discard(book_id)
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

                written = await self.abs_client.download_file(
                    book_id, source.ino, work_file, on_progress=report
                )
                done_bytes += source.size or work_file.stat().st_size
                log.info(
                    "%s: downloaded %s (%.1f MB)",
                    item.title,
                    source.filename,
                    written / 1024**2,
                )

                for position, segment in enumerate(segments):
                    log.info(
                        "%s: segment %d/%d %s (%.0fs)",
                        item.title,
                        segment.index + 1,
                        len(plan.segments),
                        segment.title,
                        segment.duration,
                    )
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
                        bitrate_kbps=bitrate,
                    )
                    manifest_segments.append(
                        {
                            "index": segment.index,
                            "title": segment.title,
                            "duration": round(segment.duration, 3),
                            "book_start": segment.book_start,
                            "bytes": size,
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
                # The source file is useless from here on. It must not occupy
                # disk, whether the cut succeeded or not.
                work_file.unlink(missing_ok=True)
                parent = work_file.parent
                if parent.exists() and not any(parent.iterdir()):
                    parent.rmdir()

        manifest_segments.sort(key=lambda s: s["index"])
        self.cache.store_manifest(
            book_id,
            {
                "book_id": book_id,
                "title": item.title,
                "author": item.author,
                "duration": round(plan.total_duration, 3),
                "chapter_source": plan.chapter_source,
                "prepared_at": time.time(),
                "segments": manifest_segments,
            },
        )
        self.cache.touch(book_id)
        self._set(
            book_id,
            status=Status.READY,
            percent=100,
            segment_count=len(manifest_segments),
        )
        log.info("%s prepared: %d segments", item.title, len(manifest_segments))
