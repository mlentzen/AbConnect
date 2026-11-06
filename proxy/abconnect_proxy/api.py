"""HTTP contract for the watch.

Responses stay deliberately small: Connect IQ aborts large JSON responses with
-402 or -403, long before a full Audiobookshelf response would fit through.

The bearer token decides who is asking. Every /v1 call uses that user's
Audiobookshelf and playlist. Prepared books live in one shared cache.
"""

from __future__ import annotations

import asyncio
import json
import logging
from contextlib import asynccontextmanager
from uuid import uuid4

from fastapi import Depends, FastAPI, HTTPException, Request
from fastapi.responses import FileResponse, JSONResponse
from pydantic import BaseModel, Field
from starlette.background import BackgroundTask

from . import auth, media, progress
from .abs_client import AbsClient, AbsError
from .cache import SAFE_ID, UnsafeBookId, check_id
from .config import Config
from .preparer import Status
from .users import UserRuntime, build_runtimes
from .watcher import MAX_PLAYLIST_BOOKS

log = logging.getLogger(__name__)

MAX_BODY_BYTES = 64 * 1024
MAX_SEGMENTS_PAGE_BYTES = 4096


class ProgressEntry(BaseModel):
    """One listening position reported by the watch.

    Attributes:
        book_id: Audiobookshelf library-item id.
        segment: Segment index.
        offset: Seconds into that segment.
        ts: When the watch observed the position, in seconds. 0 means the
            watch is asking where to resume and has nothing newer to report.
    """

    book_id: str = Field(pattern=SAFE_ID.pattern)
    segment: int = Field(ge=0)
    offset: float = Field(ge=0)
    ts: float = Field(ge=0)


class ProgressBatch(BaseModel):
    """The positions one sync hands over.

    Attributes:
        entries: Positions from the watch. Only the newest entry per book is
            kept. The limit is twice the playlist size because a sync can send
            positions of books that left the watch as well as current ones.
    """

    entries: list[ProgressEntry] = Field(
        default_factory=list, max_length=MAX_PLAYLIST_BOOKS * 2
    )


def create_app(
    config: Config, *, abs_clients: dict[str, AbsClient] | None = None
) -> FastAPI:
    """Build the HTTP app: one process, every configured user inside it.

    Args:
        config: The loaded process configuration.
        abs_clients: User name mapped to an Audiobookshelf client that
            already exists. Tests pass fakes here, and nothing then dials
            the network. A user with no entry gets a client built from their
            abs_url and abs_api_key. A client passed in is not closed on
            shutdown; the caller still holds it. Clients created here are
            closed. Omit it in production.

    Returns:
        The FastAPI application.
    """
    injected = abs_clients or {}

    def _cleanup_stale_pull_files() -> None:
        pull_dir = config.work_dir / "pull"
        for path in pull_dir.rglob("*"):
            if not path.is_file():
                continue
            try:
                path.unlink()
            except OSError as error:
                log.warning("Could not remove stale pull file %s: %s", path, error)

    @asynccontextmanager
    async def lifespan(app: FastAPI):
        app.state.config = config
        _cleanup_stale_pull_files()
        # One semaphore for every user: a single prepare job at a time.
        app.state.users = build_runtimes(
            config, asyncio.Semaphore(1), injected
        )
        app.state.failures = auth.FailureTracker()
        # Run in the background so a book newly added to a playlist is already
        # segmented and ready before that user's watch syncs the next time.
        watchers = [
            asyncio.create_task(
                user.watcher.run_forever(), name=f"playlist-watcher:{name}"
            )
            for name, user in app.state.users.items()
        ]
        try:
            yield
        finally:
            tasks = watchers
            for task in tasks:
                task.cancel()
            await asyncio.gather(*tasks, return_exceptions=True)
            stopped: set[int] = set()
            for name, user in app.state.users.items():
                # One preparer serves every user. Shutting it down twice
                # would cancel jobs that have already been cleaned up.
                if id(user.preparer) not in stopped:
                    stopped.add(id(user.preparer))
                    await user.preparer.shutdown()
                if name not in injected:
                    await user.abs.aclose()

    # The proxy is designed to face the internet: documentation is hidden
    app = FastAPI(
        title="abconnect-proxy",
        lifespan=lifespan,
        docs_url=None,
        redoc_url=None,
        openapi_url=None,
    )
    app.add_middleware(BodyLimit)
    _register(app)
    return app


class BodyLimit:
    """Refuses oversized request bodies before anything buffers them.

    FastAPI parses a body before it resolves current_user, so without this a
    caller without a token could make the proxy read any amount of data.

    Attributes:
        app: The wrapped ASGI app.
        max_bytes: Bodies larger than this are answered with HTTP 413.
    """

    def __init__(self, app, max_bytes: int = MAX_BODY_BYTES) -> None:
        """Wrap an ASGI app with a body-size limit.

        Args:
            app: The wrapped ASGI app.
            max_bytes: Maximum accepted body size, in bytes.
        """
        self.app = app
        self.max_bytes = max_bytes

    async def __call__(self, scope, receive, send) -> None:
        if scope["type"] != "http":
            await self.app(scope, receive, send)
            return

        declared = dict(scope["headers"]).get(b"content-length", b"")
        if declared.isdigit() and int(declared) > self.max_bytes:
            response = JSONResponse(
                {"detail": "Request body too large"}, status_code=413
            )
            await response(scope, receive, send)
            return

        # A chunked body declares no length; count it as it arrives.
        received = 0

        async def limited_receive():
            nonlocal received
            message = await receive()
            if message["type"] == "http.request":
                received += len(message.get("body", b""))
                if received > self.max_bytes:
                    raise HTTPException(413, "Request body too large")
            return message

        await self.app(scope, limited_receive, send)


# --- Access control --------------------------------------------------------


async def current_user(request: Request) -> UserRuntime:
    """Resolve the bearer token to its user.

    The token is the only identity the watch has. A missing or unknown token
    is HTTP 401. Too many failures from one address are HTTP 429.

    Args:
        request: The incoming request. The token is read from Authorization.

    Returns:
        That user's runtime.

    Raises:
        HTTPException: The token is missing, invalid, or the client is locked out.
    """
    config: Config = request.app.state.config
    failures: auth.FailureTracker = request.app.state.failures
    client = request.client.host if request.client else "unknown"

    remaining = failures.locked(client)
    if remaining:
        log.warning(
            "%s locked out for %d more s (too many failed attempts)",
            client,
            int(remaining),
        )
        raise HTTPException(
            429, f"Too many failed attempts, locked for {int(remaining)} s"
        )

    presented = auth.token_from_header(request.headers.get("authorization"))
    user = auth.match_user(presented, config.users) if presented else None
    if user is None:
        failures.record_failure(client)
        log.warning("%s presented a missing or invalid token", client)
        raise HTTPException(401, "Token missing or invalid")
    failures.record_success(client)
    return request.app.state.users[user.name]


def _book_id(book_id: str) -> str:
    try:
        return check_id(book_id)
    except UnsafeBookId as error:
        log.warning("Rejected unsafe book id %r: %s", book_id, error)
        raise HTTPException(400, str(error)) from None


async def _user_health(user: UserRuntime) -> dict:
    entry = {
        "audiobookshelf": "ok",
        "playlist": user.config.playlist,
        "books_cached": len(user.cache.books()),
        "cache_bytes": user.cache.total_bytes(),
    }
    try:
        await user.abs.ping()
    except AbsError as error:
        entry["audiobookshelf"] = str(error)
    last = user.watcher.last
    entry["playlist_found"] = last.found
    if last.error:
        entry["playlist_error"] = last.error
    return entry


def _register(app: FastAPI) -> None:
    # --- Operations --------------------------------------------------------

    @app.get("/health")
    async def health():
        """Report that the process answers.

        Public, so the body says nothing else and the handler calls nothing.
        The details are behind a token at /v1/status.

        Returns:
            ``{"status": "ok"}``.
        """
        return {"status": "ok"}

    @app.get("/v1/status")
    async def user_status(user: UserRuntime = Depends(current_user)):
        """Check the caller's Audiobookshelf, playlist and ffmpeg.

        A misconfiguration would otherwise only surface on a watch's first
        sync. The playlist and the server are the caller's. The cache is
        shared, so the book count covers every prepared book. No other
        user's name appears.

        Args:
            user: The caller, from their bearer token.

        Returns:
            HTTP 200 when Audiobookshelf and ffmpeg are usable, otherwise 503.
        """
        report = await _user_health(user)
        report["ffmpeg"] = True
        try:
            media.ensure_available()
        except media.MediaError as error:
            report["ffmpeg"] = False
            report["ffmpeg_error"] = str(error)

        healthy = report["ffmpeg"] and report["audiobookshelf"] == "ok"
        return JSONResponse(report, status_code=200 if healthy else 503)

    # --- Library ----------------------------------------------------------

    @app.get("/v1/playlist")
    async def playlist(user: UserRuntime = Depends(current_user)):
        """Return the target playlist for the watch.

        The playlist is refreshed on every call so a just-added book starts
        preparing immediately instead of waiting for the next background pass.
        A playlist name that does not exist is HTTP 409, so the watch does
        not treat it as an empty library.

        Args:
            user: The caller, from their bearer token.

        Returns:
            The playlist name, whether it was found, and each book's status.
        """
        result = await user.watcher.refresh()

        books = []
        for book in result.books[:MAX_PLAYLIST_BOOKS]:
            state = user.preparer.status(book["id"])
            entry = {
                "id": book["id"],
                "title": book["title"],
                "author": book["author"],
                "duration": book["duration"],
                "status": state.status.value,
            }
            if state.status is Status.PREPARING:
                entry["percent"] = state.percent
            if state.status is Status.READY:
                entry["segments"] = state.segment_count
            if state.status is Status.ERROR:
                entry["error"] = state.error
            books.append(entry)

        payload = {
            "playlist": user.config.playlist,
            "found": result.found,
            "books": books,
            "total": result.total,
        }
        if result.error:
            payload["error"] = result.error
        return JSONResponse(payload, status_code=200 if result.found else 409)

    @app.get("/v1/books/{book_id}/segments")
    async def segments(
        book_id: str,
        after: int | None = None,
        user: UserRuntime = Depends(current_user),
    ):
        """Return one page of the segment list for a prepared book.

        Args:
            book_id: Audiobookshelf library-item id.
            after: Last segment index the watch already has. The page starts
                at the next one. Omit it for the first page.
            user: The caller, from their bearer token.

        Returns:
            One page of segments. ``next`` is the cursor to send back as
            ``after`` when another page remains, and null on the last page.
            Only the first page also says where Audiobookshelf would resume.

        Raises:
            HTTPException: The book id is unsafe, or the book is not ready.
        """
        book_id = _book_id(book_id)
        manifest = user.cache.load_manifest(book_id)
        if manifest is None:
            state = user.preparer.status(book_id)
            raise HTTPException(
                409, f"Book is not ready (status: {state.status.value})"
            )
        user.cache.touch(book_id)

        listing = [
            {
                "index": entry["index"],
                "title": entry["title"],
                "duration": entry["duration"],
                "bytes": entry["bytes"],
                "url": f"/v1/books/{book_id}/seg/{entry['file']}",
            }
            for entry in manifest["segments"]
            if after is None or entry["index"] > after
        ]

        # A chapter-heavy book easily outgrows what the watch's sync request
        # can hold, so only as much fits as stays under budget. One entry at
        # least, so a single oversized title can't stall pagination forever.
        # +2 for the array's own brackets, +2 per separating ", ", matching
        # what json.dumps(page) actually produces, not just the entries summed.
        page: list[dict] = []
        page_bytes = 2
        for entry in listing:
            entry_bytes = len(json.dumps(entry)) + (2 if page else 0)
            if page and page_bytes + entry_bytes > MAX_SEGMENTS_PAGE_BYTES:
                break
            page.append(entry)
            page_bytes += entry_bytes
        # `next` is the cursor the watch echoes back as `after`, the index of
        # the last segment it now has, not the one it still needs.
        next_index = page[-1]["index"] if len(page) < len(listing) else None

        payload = {
            "id": book_id,
            "title": manifest["title"],
            "author": manifest["author"],
            "duration": manifest["duration"],
            "chapter_source": manifest["chapter_source"],
            "segments": page,
            "next": next_index,
        }

        # Where the server would resume. The watch decides during sync whether
        # its own position is more recent. Only worth the extra ABS call once,
        # on the first page; later pages have nothing new to say about it.
        if after is None:
            try:
                stored = await user.abs.get_progress(book_id)
            except AbsError:
                stored = None
            if stored and stored.get("currentTime"):
                spot = progress.position(
                    manifest["segments"], float(stored["currentTime"])
                )
                payload["resume"] = {
                    "segment": spot.segment,
                    "offset": spot.offset,
                    "ts": progress.server_timestamp(stored),
                }
        return payload

    @app.get("/v1/books/{book_id}/seg/{filename}")
    async def segment_file(
        book_id: str,
        filename: str,
        request: Request,
        user: UserRuntime = Depends(current_user),
    ):
        """Return the audio file for one segment from the shared cache.

        ``bitrate_kbps`` re-encodes the chapter to that file rate and keeps
        its channels. ``mono`` also mixes it to one channel. Either one is
        enough to take this path; with only ``mono``, the rate is the
        process-wide one. A file that already matches is sent unchanged.
        Otherwise the copy is written under the work directory and removed
        after the response. The cached file stays as prepared.

        Args:
            book_id: Audiobookshelf library-item id.
            filename: Segment file name, as listed by the segments endpoint.
            request: The incoming request. The work directory comes from the
                app config.
            user: The caller, from their bearer token.

        Returns:
            The segment file, or a temporary re-encode of it.

        Raises:
            HTTPException: The name is unsafe, the file is not in the cache,
                or the mono mix could not be written.
        """
        book_id = _book_id(book_id)
        try:
            path = user.cache.segment_path(book_id, filename)
        except UnsafeBookId as error:
            raise HTTPException(400, str(error)) from None
        if not path.exists():
            raise HTTPException(404, "Segment not found")
        user.cache.touch(book_id)
        if not user.config.mono and user.config.bitrate_kbps is None:
            return FileResponse(path, media_type="audio/mpeg")

        config: Config = request.app.state.config
        bitrate = user.config.bitrate_kbps
        if bitrate is None:
            bitrate = config.transcode_bitrate_kbps
        try:
            reencode = await media.needs_reencode(path, bitrate, mono=user.config.mono)
        except media.MediaError as error:
            log.error("Re-encode of %s/%s failed: %s", book_id, filename, error)
            raise HTTPException(500, "Segment could not be prepared") from None
        if not reencode:
            return FileResponse(path, media_type="audio/mpeg")

        destination = config.work_dir / "pull" / f"{uuid4().hex}.mp3"
        try:
            await media.reencode(
                path, destination, bitrate_kbps=bitrate, mono=user.config.mono
            )
        except media.MediaError as error:
            log.error("Re-encode of %s/%s failed: %s", book_id, filename, error)
            destination.unlink(missing_ok=True)
            raise HTTPException(500, "Segment could not be prepared") from None
        except asyncio.CancelledError:
            destination.unlink(missing_ok=True)
            raise
        return FileResponse(
            destination,
            media_type="audio/mpeg",
            background=BackgroundTask(destination.unlink, missing_ok=True),
        )

    # --- Progress ---------------------------------------------------------

    @app.post("/v1/progress")
    async def push_progress(
        batch: ProgressBatch, user: UserRuntime = Depends(current_user)
    ):
        """Merge the watch's positions into that user's Audiobookshelf.

        The newer timestamp wins, and a tie goes to the watch. When the
        server is ahead, the response tells the watch where to jump.

        Args:
            batch: Positions from one sync. Only the newest entry per book
                is applied.
            user: The caller, from their bearer token.

        Returns:
            Per book, whether the position was accepted and which side won.
        """
        newest: dict[str, ProgressEntry] = {}
        for entry in batch.entries:
            known = newest.get(entry.book_id)
            if known is None or entry.ts > known.ts:
                newest[entry.book_id] = entry

        results = []
        for book_id, entry in newest.items():
            manifest = user.cache.load_manifest(book_id)
            if manifest is None:
                results.append({"id": book_id, "accepted": False})
                continue

            watch_time = progress.book_time(
                manifest["segments"], entry.segment, entry.offset
            )
            try:
                stored = await user.abs.get_progress(book_id)
            except AbsError:
                stored = None

            server_time = float((stored or {}).get("currentTime") or 0.0)
            server_ts = progress.server_timestamp(stored)
            winner, winning_time = progress.choose(
                watch_time=watch_time,
                watch_ts=entry.ts,
                server_time=server_time,
                server_ts=server_ts,
            )
            log.info(
                "%s/%s: watch %.1fs@%.0f vs server %.1fs@%.0f -> %s wins (%.1fs)",
                user.config.name,
                book_id,
                watch_time,
                entry.ts,
                server_time,
                server_ts,
                winner,
                winning_time,
            )

            result = {"id": book_id, "accepted": True, "source": winner}
            if winner == "watch":
                # Timestamp 0 is the watch asking, not reporting: it holds
                # nothing newer than what it was last told. Written back, a book
                # never started anywhere would land in ABS at 0 s, "in progress".
                if entry.ts > 0:
                    try:
                        await user.abs.set_progress(
                            book_id,
                            current_time=winning_time,
                            duration=float(manifest["duration"]),
                        )
                    except AbsError as error:
                        log.warning(
                            "%s: progress push for %s failed: %s",
                            user.config.name,
                            book_id,
                            error,
                        )
                        result["accepted"] = False
            else:
                # The server is ahead. The watch should jump there.
                spot = progress.position(manifest["segments"], winning_time)
                result["resume"] = {"segment": spot.segment, "offset": spot.offset}
            results.append(result)

        return {"books": results}
