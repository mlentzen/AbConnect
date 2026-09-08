"""HTTP-Vertrag zur Uhr.

Antworten bleiben bewusst schmal: Connect IQ bricht große JSON-Antworten mit
-402 beziehungsweise -403 ab, lange bevor eine ABS-Antwort durchpassen würde.
"""

from __future__ import annotations

import asyncio
import logging
import math
import time
from contextlib import asynccontextmanager

from fastapi import Depends, FastAPI, HTTPException, Query, Request
from fastapi.responses import FileResponse, JSONResponse
from pydantic import BaseModel, Field

from . import auth, media, progress
from .abs_client import AbsAuthError, AbsClient, AbsError
from .cache import Cache, UnsafeBookId
from .config import Config
from .preparer import Preparer, Status

log = logging.getLogger(__name__)

SWEEP_INTERVAL_SECONDS = 3600
COVER_WIDTH = 300


class ProgressEntry(BaseModel):
    book_id: str
    segment: int = Field(ge=0)
    offset: float = Field(ge=0)
    ts: float = Field(ge=0)


class ProgressBatch(BaseModel):
    entries: list[ProgressEntry] = Field(default_factory=list, max_length=200)


def create_app(config: Config, *, abs_client: AbsClient | None = None) -> FastAPI:
    @asynccontextmanager
    async def lifespan(app: FastAPI):
        app.state.config = config
        app.state.cache = Cache(root=config.cache_dir)
        app.state.abs = abs_client or AbsClient(
            config.abs_url, config.abs_api_key, timeout=config.http_timeout_seconds
        )
        app.state.preparer = Preparer(
            abs_client=app.state.abs, cache=app.state.cache, config=config
        )
        app.state.failures = auth.FailureTracker()
        sweeper = asyncio.create_task(_sweep_forever(app), name="cache-sweeper")
        try:
            yield
        finally:
            sweeper.cancel()
            await asyncio.gather(sweeper, return_exceptions=True)
            await app.state.preparer.shutdown()
            if abs_client is None:
                await app.state.abs.aclose()

    app = FastAPI(title="abconnect-proxy", version="0.1.0", lifespan=lifespan)
    _register(app)
    return app


async def _sweep_forever(app: FastAPI) -> None:
    while True:
        try:
            await asyncio.sleep(SWEEP_INTERVAL_SECONDS)
            cache: Cache = app.state.cache
            config: Config = app.state.config
            for book_id in cache.sweep(config.release_ttl_days):
                app.state.preparer.forget(book_id)
            for book_id in cache.enforce_budget(config.cache_max_bytes):
                app.state.preparer.forget(book_id)
        except asyncio.CancelledError:
            raise
        except Exception:  # pragma: no cover - der Sweeper darf nie den Prozess reißen
            log.exception("Cache-Sweep gescheitert")


# --- Zugangskontrolle --------------------------------------------------------


async def require_token(request: Request) -> None:
    config: Config = request.app.state.config
    failures: auth.FailureTracker = request.app.state.failures
    client = request.client.host if request.client else "unbekannt"

    remaining = failures.locked(client)
    if remaining:
        raise HTTPException(429, f"Zu viele Fehlversuche, {int(remaining)} s sperren")

    presented = auth.token_from_header(request.headers.get("authorization"))
    if not presented or not auth.verify_token(presented, config.tokens):
        failures.record_failure(client)
        raise HTTPException(401, "Token fehlt oder ist ungültig")
    failures.record_success(client)


def _book_id(book_id: str) -> str:
    try:
        from .cache import check_id

        return check_id(book_id)
    except UnsafeBookId as error:
        raise HTTPException(400, str(error)) from None


def _register(app: FastAPI) -> None:
    guarded = [Depends(require_token)]

    # --- Betrieb -------------------------------------------------------------

    @app.get("/healthz")
    async def healthz(request: Request):
        """Prüft Konfiguration *und* ABS-Erreichbarkeit — sonst fällt eine
        Fehlkonfiguration erst beim ersten Sync der Uhr auf."""
        cache: Cache = request.app.state.cache
        config: Config = request.app.state.config
        report = {
            "abs_url": config.abs_url,
            "cache_bytes": cache.total_bytes(),
            "cache_max_bytes": config.cache_max_bytes,
            "books_cached": len(cache.books()),
            "ffmpeg": True,
            "audiobookshelf": "ok",
        }
        try:
            media.ensure_available()
        except media.MediaError as error:
            report["ffmpeg"] = False
            report["ffmpeg_error"] = str(error)
        try:
            await request.app.state.abs.ping()
        except AbsError as error:
            report["audiobookshelf"] = str(error)

        healthy = report["ffmpeg"] and report["audiobookshelf"] == "ok"
        return JSONResponse(report, status_code=200 if healthy else 503)

    # --- Bibliothek ----------------------------------------------------------

    @app.get("/v1/books", dependencies=guarded)
    async def list_books(
        request: Request,
        page: int = Query(1, ge=1),
        per_page: int = Query(20, ge=1, le=100),
        q: str = Query("", max_length=100),
    ):
        try:
            books = await request.app.state.abs.all_books()
        except AbsAuthError as error:
            raise HTTPException(502, str(error)) from None
        except AbsError as error:
            raise HTTPException(503, str(error)) from None

        if q:
            needle = q.casefold()
            books = [b for b in books if needle in b["title"].casefold() or needle in b["author"].casefold()]

        total = len(books)
        start = (page - 1) * per_page
        preparer: Preparer = request.app.state.preparer

        page_items = []
        for book in books[start : start + per_page]:
            state = preparer.status(book["id"])
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
            page_items.append(entry)

        return {
            "books": page_items,
            "page": page,
            "pages": max(1, math.ceil(total / per_page)),
            "total": total,
        }

    @app.post("/v1/books/{book_id}/prepare", dependencies=guarded)
    async def prepare(request: Request, book_id: str):
        state = request.app.state.preparer.request(_book_id(book_id))
        return {"status": state.status.value, "percent": state.percent}

    @app.get("/v1/books/{book_id}/status", dependencies=guarded)
    async def book_status(request: Request, book_id: str):
        state = request.app.state.preparer.status(_book_id(book_id))
        payload = {"status": state.status.value, "percent": state.percent}
        if state.error:
            payload["error"] = state.error
        if state.segment_count:
            payload["segments"] = state.segment_count
        return payload

    @app.get("/v1/books/{book_id}/segments", dependencies=guarded)
    async def segments(request: Request, book_id: str):
        book_id = _book_id(book_id)
        cache: Cache = request.app.state.cache
        manifest = cache.load_manifest(book_id)
        if manifest is None:
            state = request.app.state.preparer.status(book_id)
            raise HTTPException(409, f"Buch ist nicht bereit (Status: {state.status.value})")
        cache.touch(book_id)

        config: Config = request.app.state.config
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
        ]

        payload = {
            "id": book_id,
            "title": manifest["title"],
            "author": manifest["author"],
            "duration": manifest["duration"],
            "chapter_source": manifest["chapter_source"],
            "segments": listing,
        }
        if manifest.get("cover"):
            expires = int(time.time()) + config.cover_url_ttl_seconds
            signature = auth.sign_cover(book_id, expires, config.signing_key)
            payload["cover_url"] = (
                f"/v1/books/{book_id}/cover.jpg?w={COVER_WIDTH}&exp={expires}&sig={signature}"
            )

        # Wo der Server weiterhören würde — die Uhr entscheidet beim Sync selbst,
        # ob ihr eigener Stand jünger ist.
        try:
            stored = await request.app.state.abs.get_progress(book_id)
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

    @app.get("/v1/books/{book_id}/seg/{filename}", dependencies=guarded)
    async def segment_file(request: Request, book_id: str, filename: str):
        book_id = _book_id(book_id)
        cache: Cache = request.app.state.cache
        try:
            path = cache.segment_path(book_id, filename)
        except UnsafeBookId as error:
            raise HTTPException(400, str(error)) from None
        if not path.exists():
            raise HTTPException(404, "Segment nicht vorhanden")
        cache.touch(book_id)
        media_type = "audio/mp4" if path.suffix == ".m4a" else "audio/mpeg"
        return FileResponse(path, media_type=media_type)

    @app.get("/v1/books/{book_id}/cover.jpg")
    async def cover(
        request: Request,
        book_id: str,
        exp: int = Query(...),
        sig: str = Query(...),
        w: int = Query(COVER_WIDTH, ge=32, le=1024),
    ):
        # Ohne Bearer: makeImageRequest kann keine Header setzen. Statt des
        # langlebigen Tokens im Query-String trägt die URL eine kurzlebige
        # Signatur, die in keinem Log Schaden anrichtet.
        book_id = _book_id(book_id)
        config: Config = request.app.state.config
        if not auth.verify_cover(book_id, exp, sig, config.tokens):
            raise HTTPException(403, "Cover-Signatur ungültig oder abgelaufen")
        path = request.app.state.cache.cover_path(book_id)
        if not path.exists():
            raise HTTPException(404, "Kein Cover vorhanden")
        return FileResponse(path, media_type="image/jpeg")

    @app.post("/v1/books/{book_id}/release", dependencies=guarded)
    async def release(request: Request, book_id: str):
        book_id = _book_id(book_id)
        request.app.state.cache.release(book_id)
        return {"released": book_id}

    # --- Fortschritt ---------------------------------------------------------

    @app.post("/v1/progress", dependencies=guarded)
    async def push_progress(request: Request, batch: ProgressBatch):
        cache: Cache = request.app.state.cache
        abs_client = request.app.state.abs

        newest: dict[str, ProgressEntry] = {}
        for entry in batch.entries:
            known = newest.get(entry.book_id)
            if known is None or entry.ts > known.ts:
                newest[entry.book_id] = entry

        results = []
        for book_id, entry in newest.items():
            manifest = cache.load_manifest(book_id)
            if manifest is None:
                results.append({"id": book_id, "accepted": False, "reason": "nicht vorbereitet"})
                continue

            watch_time = progress.book_time(manifest["segments"], entry.segment, entry.offset)
            try:
                stored = await abs_client.get_progress(book_id)
            except AbsError:
                stored = None

            winner, winning_time = progress.reconcile(
                watch_time=watch_time,
                watch_ts=entry.ts,
                server_time=float((stored or {}).get("currentTime") or 0.0),
                server_ts=progress.server_timestamp(stored),
            )

            result = {"id": book_id, "accepted": True, "source": winner}
            if winner == "watch":
                try:
                    await abs_client.set_progress(
                        book_id, current_time=winning_time, duration=float(manifest["duration"])
                    )
                except AbsError as error:
                    result.update(accepted=False, reason=str(error))
            else:
                # Der Server ist weiter — die Uhr soll dorthin springen.
                spot = progress.position(manifest["segments"], winning_time)
                result["resume"] = {"segment": spot.segment, "offset": spot.offset}
            results.append(result)

        return {"books": results}
