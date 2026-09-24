# abconnect-proxy

Companion server between Audiobookshelf and the Connect IQ app.

It downloads an `.m4b` via the ABS API, cuts it losslessly into chapter-wise
segments of 10–20 minutes and deletes the source file again right away. The
watch only gets lean JSON responses and finished segments; the ABS API key
stays here.

Why at all: a single `.m4b` on the watch is one track spanning twelve hours
with no chapter navigation, and Connect IQ aborts large JSON responses anyway.
Details in [../docs/PLAN.md](../docs/PLAN.md).

## Modules

Request path first, then the background work:

| Module | Role |
|---|---|
| `__main__.py` | entry point: loads the config, starts uvicorn |
| `config.py` | environment + `users.toml`, validated all at once at start |
| `api.py` | FastAPI app: routes, body limit, token → user, background tasks |
| `auth.py` | constant-time token match, failure backoff per client address |
| `pairing.py` | short-lived pairing codes that move a token from phone to watch |
| `users.py` | one runtime per user: ABS client, cache, preparer, reconciler |
| `abs_client.py` | Audiobookshelf HTTP API (the only place the API key is used) |
| `parsing.py`, `models.py` | lenient ABS JSON → internal models |
| `reconciler.py` | playlist → what should be prepared or released |
| `preparer.py` | per book: download, cut, write manifest, delete the source |
| `segmenter.py` | pure computation: chapters → segment plan (10–20 min) |
| `media.py` | ffmpeg/ffprobe (stream copy, re-encode only when needed) |
| `cache.py` | segment cache on disk, manifests, shared disk budget |
| `progress.py` | (segment, offset) ↔ book time, "newer wins" reconciliation |

## HTTP API

`/v1/*` needs `Authorization: Bearer <token>`. The token selects the user.
Five failures within a minute lock the client address out for 60 s.

| Route | Purpose |
|---|---|
| `GET /health` | liveness only, public |
| `GET /v1/status` | the caller's ABS, playlist and ffmpeg state; 503 when unhealthy |
| `GET /v1/playlist` | books in the user's playlist with prepare status; 409 when the playlist is missing |
| `GET /v1/books/{id}/segments?after=N` | segment list, paginated (`next` is the cursor) |
| `GET /v1/books/{id}/seg/{file}` | one segment file |
| `POST /v1/progress` | batch of watch positions; answers with who won and where to resume |
| `POST /pair/start` | public: new pairing code for a watch |
| `GET /pair`, `POST /pair` | public: phone form, code + token (token must be valid) |
| `GET /pair/{code}` | public: 202 pending, 200 `{token}` once, 404 unknown/expired |

The pairing routes have their own backoff, so a phone that mistypes a code does
not lock the watch out of `/v1`.

## Development

```sh
python3 -m venv .venv && .venv/bin/pip install -e '.[dev]'
.venv/bin/python -m pytest
```

The tests need `ffmpeg` and `ffprobe` on the `PATH` — they create real m4b
files with chapter markers, cut them and verify the result with `ffprobe`.
Without ffmpeg these tests are skipped, the rest runs.

Operation and configuration: [../deploy/README.md](../deploy/README.md).
