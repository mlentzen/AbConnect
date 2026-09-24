"""HTTP contract for the watch.

Responses stay deliberately small: Connect IQ aborts large JSON responses with
-402 or -403, long before a full ABS response would fit through.

The bearer token decides who is asking. Every /v1 call runs against that
user's own Audiobookshelf, cache and playlist.
"""

from __future__ import annotations

import asyncio
import html
import json
import logging
from contextlib import asynccontextmanager
from urllib.parse import parse_qs

from fastapi import Depends, FastAPI, HTTPException, Request
from fastapi.responses import FileResponse, HTMLResponse, JSONResponse
from pydantic import BaseModel, Field

from . import auth, media, progress
from .abs_client import AbsClient, AbsError
from .cache import SAFE_ID, UnsafeBookId
from .config import Config
from .pairing import CODE_TTL_SECONDS, PairingFull, PairingRegistry
from .preparer import Status
from .users import UserRuntime, build_runtimes

log = logging.getLogger(__name__)

SWEEP_INTERVAL_SECONDS = 3600
# The watch aborts large JSON responses; a sync playlist with more than a
# hundred books would not fit on it anyway.
MAX_PLAYLIST_BOOKS = 100
# A full progress batch of 200 entries is about 20 KB.
MAX_BODY_BYTES = 64 * 1024
# Segments are cut at chapter boundaries, so a chapter-heavy book can carry
# far more of them than SEGMENT_TARGET_SECONDS would suggest — a book with
# ~100 chapters was seen sending -402 (response too large) to the watch, even
# though the request to this proxy itself succeeded. Paginated below the
# tightest reported sync-request budget (a few KB) rather than sized for it.
MAX_SEGMENTS_PAGE_BYTES = 4096


class ProgressEntry(BaseModel):
    book_id: str = Field(pattern=SAFE_ID.pattern)
    segment: int = Field(ge=0)
    offset: float = Field(ge=0)
    ts: float = Field(ge=0)


class ProgressBatch(BaseModel):
    entries: list[ProgressEntry] = Field(default_factory=list, max_length=200)


def create_app(config: Config, *, abs_clients: dict[str, AbsClient] | None = None) -> FastAPI:
    """`abs_clients` injects ABS clients by user name (tests); those are not closed here."""
    injected = abs_clients or {}

    @asynccontextmanager
    async def lifespan(app: FastAPI):
        app.state.config = config
        # One semaphore for every user: a single prepare job at a time.
        app.state.users, app.state.budget = build_runtimes(config, asyncio.Semaphore(1), injected)
        app.state.failures = auth.FailureTracker()
        # Pairing is public, so it gets a backoff of its own: a phone fumbling
        # a code must not lock the watch out of /v1 behind the same address.
        app.state.pairing = PairingRegistry()
        app.state.pair_failures = auth.FailureTracker()
        sweeper = asyncio.create_task(_sweep_forever(app), name="cache-sweeper")
        # Run in the background so a book newly added to a playlist is already
        # segmented and ready before that user's watch syncs the next time.
        watchers = [
            asyncio.create_task(user.reconciler.run_forever(), name=f"playlist-watcher:{name}")
            for name, user in app.state.users.items()
        ]
        try:
            yield
        finally:
            tasks = [sweeper, *watchers]
            for task in tasks:
                task.cancel()
            await asyncio.gather(*tasks, return_exceptions=True)
            for name, user in app.state.users.items():
                await user.preparer.shutdown()
                if name not in injected:
                    await user.abs.aclose()

    # The proxy faces the internet: no generated docs that map out the API.
    app = FastAPI(
        title="abconnect-proxy",
        version="0.1.0",
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

    FastAPI parses a body before it resolves `current_user`, so without this a
    caller without a token could make the proxy read any amount of data.
    """

    def __init__(self, app, max_bytes: int = MAX_BODY_BYTES) -> None:
        self.app = app
        self.max_bytes = max_bytes

    async def __call__(self, scope, receive, send) -> None:
        if scope["type"] != "http":
            await self.app(scope, receive, send)
            return

        declared = dict(scope["headers"]).get(b"content-length", b"")
        if declared.isdigit() and int(declared) > self.max_bytes:
            response = JSONResponse({"detail": "Request body too large"}, status_code=413)
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


async def _sweep_forever(app: FastAPI) -> None:
    while True:
        try:
            await asyncio.sleep(SWEEP_INTERVAL_SECONDS)
            config: Config = app.state.config
            users: dict[str, UserRuntime] = app.state.users
            for user in users.values():
                for book_id in user.cache.sweep(config.release_ttl_days):
                    user.preparer.forget(book_id)
            for owner, book_id in app.state.budget.enforce():
                users[owner].preparer.forget(book_id)
        except asyncio.CancelledError:
            raise
        except Exception:  # pragma: no cover - the sweeper must never take down the process
            log.exception("Cache sweep failed")


# --- Access control --------------------------------------------------------


async def current_user(request: Request) -> UserRuntime:
    """Resolves the bearer token to its user — the only identity the watch has."""
    config: Config = request.app.state.config
    failures: auth.FailureTracker = request.app.state.failures
    client = request.client.host if request.client else "unknown"

    remaining = failures.locked(client)
    if remaining:
        log.warning("%s locked out for %d more s (too many failed attempts)", client, int(remaining))
        raise HTTPException(429, f"Too many failed attempts, locked for {int(remaining)} s")

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
        from .cache import check_id

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
    last = user.reconciler.last
    entry["playlist_found"] = last.found
    if last.error:
        entry["playlist_error"] = last.error
    return entry


def _register(app: FastAPI) -> None:
    # --- Operations --------------------------------------------------------

    @app.get("/health")
    async def health():
        """Liveness only: the process answers.

        Public, so it says nothing else and calls nothing — the details are
        behind a token at /v1/status.
        """
        return {"status": "ok"}

    @app.get("/v1/status")
    async def user_status(user: UserRuntime = Depends(current_user)):
        """Checks the caller's ABS, playlist and ffmpeg — otherwise a
        misconfiguration would only surface on a watch's first sync.

        Reports the caller's own state only; no other user shows up here.
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
        """The target playlist for the watch.

        Reconciliation runs on every call so a just-added book is prepared
        immediately instead of only on the next background pass.
        """
        result = await user.reconciler.reconcile()

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
            "total": len(result.books),
        }
        if result.error:
            payload["error"] = result.error
        # An unfindable playlist is a configuration error, not an empty wish —
        # the watch must not delete anything as a result.
        return JSONResponse(payload, status_code=200 if result.found else 409)

    @app.get("/v1/books/{book_id}/segments")
    async def segments(book_id: str, after: int | None = None, user: UserRuntime = Depends(current_user)):
        book_id = _book_id(book_id)
        manifest = user.cache.load_manifest(book_id)
        if manifest is None:
            state = user.preparer.status(book_id)
            raise HTTPException(409, f"Book is not ready (status: {state.status.value})")
        user.cache.touch(book_id)

        listing = [
            {
                "index": entry["index"],
                "title": entry["title"],
                "duration": entry["duration"],
                "bytes": entry["bytes"],
                "encoding": entry["encoding"],
                "url": f"/v1/books/{book_id}/seg/{entry['file']}",
            }
            for entry in manifest["segments"]
            if after is None or entry["index"] > after
        ]

        # A chapter-heavy book easily outgrows what the watch's sync request
        # can hold, so only as much fits as stays under budget — one entry at
        # least, so a single oversized title can't stall pagination forever.
        # +2 for the array's own brackets, +2 per separating ", " — matching
        # what json.dumps(page) actually produces, not just the entries summed.
        page: list[dict] = []
        page_bytes = 2
        for entry in listing:
            entry_bytes = len(json.dumps(entry)) + (2 if page else 0)
            if page and page_bytes + entry_bytes > MAX_SEGMENTS_PAGE_BYTES:
                break
            page.append(entry)
            page_bytes += entry_bytes
        # `next` is the cursor the watch echoes back as `after` — the index of
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

        # Where the server would resume — the watch decides during sync whether
        # its own position is more recent. Only worth the extra ABS call once,
        # on the first page; later pages have nothing new to say about it.
        if after is None:
            try:
                stored = await user.abs.get_progress(book_id)
            except AbsError:
                stored = None
            if stored and stored.get("currentTime"):
                spot = progress.position(manifest["segments"], float(stored["currentTime"]))
                payload["resume"] = {
                    "segment": spot.segment,
                    "offset": spot.offset,
                    "ts": progress.server_timestamp(stored),
                }
        return payload

    @app.get("/v1/books/{book_id}/seg/{filename}")
    async def segment_file(book_id: str, filename: str, user: UserRuntime = Depends(current_user)):
        book_id = _book_id(book_id)
        try:
            path = user.cache.segment_path(book_id, filename)
        except UnsafeBookId as error:
            raise HTTPException(400, str(error)) from None
        if not path.exists():
            raise HTTPException(404, "Segment not found")
        user.cache.touch(book_id)
        media_type = "audio/mp4" if path.suffix == ".m4a" else "audio/mpeg"
        return FileResponse(path, media_type=media_type)

    # --- Progress ---------------------------------------------------------

    @app.post("/v1/progress")
    async def push_progress(batch: ProgressBatch, user: UserRuntime = Depends(current_user)):
        newest: dict[str, ProgressEntry] = {}
        for entry in batch.entries:
            known = newest.get(entry.book_id)
            if known is None or entry.ts > known.ts:
                newest[entry.book_id] = entry

        results = []
        for book_id, entry in newest.items():
            manifest = user.cache.load_manifest(book_id)
            if manifest is None:
                results.append({"id": book_id, "accepted": False, "reason": "not prepared"})
                continue

            watch_time = progress.book_time(manifest["segments"], entry.segment, entry.offset)
            try:
                stored = await user.abs.get_progress(book_id)
            except AbsError:
                stored = None

            server_time = float((stored or {}).get("currentTime") or 0.0)
            server_ts = progress.server_timestamp(stored)
            winner, winning_time = progress.reconcile(
                watch_time=watch_time,
                watch_ts=entry.ts,
                server_time=server_time,
                server_ts=server_ts,
            )
            log.info(
                "%s/%s: watch %.1fs@%.0f vs server %.1fs@%.0f -> %s wins (%.1fs)",
                user.config.name, book_id, watch_time, entry.ts, server_time, server_ts, winner, winning_time,
            )

            result = {"id": book_id, "accepted": True, "source": winner}
            if winner == "watch":
                # Timestamp 0 is the watch asking, not reporting: it holds
                # nothing newer than what it was last told. Written back, a book
                # never started anywhere would land in ABS at 0 s, "in progress".
                if entry.ts > 0:
                    try:
                        await user.abs.set_progress(
                            book_id, current_time=winning_time, duration=float(manifest["duration"])
                        )
                    except AbsError as error:
                        log.warning("%s: progress push for %s failed: %s", user.config.name, book_id, error)
                        result.update(accepted=False, reason=str(error))
            else:
                # The server is ahead — the watch should jump there.
                spot = progress.position(manifest["segments"], winning_time)
                result["resume"] = {"segment": spot.segment, "offset": spot.offset}
            results.append(result)

        return {"books": results}

    # --- Pairing ------------------------------------------------------------
    #
    # The token is typed on the phone, not on the watch. See pairing.py.

    @app.post("/pair/start")
    async def pair_start(request: Request):
        """The watch asks for a code to show."""
        _pair_guard(request)
        try:
            code = request.app.state.pairing.start()
        except PairingFull:
            raise HTTPException(503, "Too many pairings open, try again later") from None
        log.info("Pairing code issued to %s", _client(request))
        return {"code": code, "expires_in": int(CODE_TTL_SECONDS)}

    @app.get("/pair/{code}")
    async def pair_poll(code: str, request: Request):
        """The watch polls: 202 while waiting, the token once, 404 when gone."""
        _pair_guard(request)
        known, token = request.app.state.pairing.poll(code)
        if not known:
            request.app.state.pair_failures.record_failure(_client(request))
            raise HTTPException(404, "Unknown or expired code")
        if token is None:
            return JSONResponse({"status": "pending"}, status_code=202)
        log.info("Pairing completed for %s", _client(request))
        return {"token": token}

    @app.get("/pair", response_class=HTMLResponse)
    async def pair_form():
        return _pair_page()

    @app.post("/pair", response_class=HTMLResponse)
    async def pair_submit(request: Request):
        """The phone hands over code and token.

        Parsed by hand: an urlencoded form of two fields does not warrant
        python-multipart as a dependency.
        """
        _pair_guard(request)
        form = parse_qs((await request.body()).decode("utf-8", "replace"))
        code = (form.get("code") or [""])[0]
        token = (form.get("token") or [""])[0].strip()
        config: Config = request.app.state.config
        failures: auth.FailureTracker = request.app.state.pair_failures
        client = _client(request)

        if not token or auth.match_user(token, config.users) is None:
            failures.record_failure(client)
            log.warning("%s tried to pair with an invalid token", client)
            return HTMLResponse(_pair_page(error="Token not valid.", code=code), status_code=401)
        if not request.app.state.pairing.complete(code, token):
            failures.record_failure(client)
            return HTMLResponse(
                _pair_page(error="Code unknown or expired. Start pairing on the watch again."),
                status_code=404,
            )
        failures.record_success(client)
        return _pair_page(done=True)


def _client(request: Request) -> str:
    return request.client.host if request.client else "unknown"


def _pair_guard(request: Request) -> None:
    remaining = request.app.state.pair_failures.locked(_client(request))
    if remaining:
        raise HTTPException(429, f"Too many failed attempts, locked for {int(remaining)} s")


def _pair_page(error: str = "", code: str = "", done: bool = False) -> str:
    if done:
        body = "<p class=ok>Paired. Look at your watch.</p>"
    else:
        message = f"<p class=err>{html.escape(error)}</p>" if error else ""
        body = f"""{message}
<form method=post action=/pair>
<label>Code shown on the watch<input name=code value="{html.escape(code)}" autocomplete=off
 autocapitalize=characters spellcheck=false required maxlength=12></label>
<label>Token<input name=token type=password autocomplete=off required></label>
<button>Pair</button>
</form>"""
    return f"""<!doctype html>
<html><head><meta charset=utf-8><meta name=viewport content="width=device-width,initial-scale=1">
<meta name=robots content=noindex><title>AbConnect pairing</title>
<style>body{{font:16px system-ui,sans-serif;max-width:26rem;margin:2rem auto;padding:0 1rem}}
label{{display:block;margin:1rem 0}}input{{display:block;width:100%;font-size:1.2rem;padding:.4rem;box-sizing:border-box}}
button{{font-size:1.1rem;padding:.5rem 1.5rem}}.err{{color:#b00}}.ok{{color:#070;font-size:1.3rem}}</style>
</head><body><h1>AbConnect</h1>{body}</body></html>"""
