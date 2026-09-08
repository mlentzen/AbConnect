# AbConnect

Audiobookshelf as a Connect IQ audio provider for Garmin music watches.

Audiobooks from a self-hosted
[Audiobookshelf](https://www.audiobookshelf.org/) instance land on the watch,
play offline through the system media player, and listening progress goes back
to the server.

## Structure

```
Audiobookshelf  <--API key--  abconnect-proxy  <--token--  fēnix 7X Pro
                (downloads the m4b)            (downloads segments)
```

**[`proxy/`](proxy/README.md)** — container next to Audiobookshelf, run as a
Podman quadlet. Downloads an `.m4b` via the ABS API, cuts it losslessly into
chapter-wise segments of 10–20 minutes, deletes the source file again right
away and keeps the ABS API key server-side.

**[`app/`](app/README.md)** — Connect IQ app of type
`audio-content-provider-app` that downloads segments, plays them and buffers
progress.

What ends up on the watch is decided by the Audiobookshelf playlist
**`Garmin`**: add a book and it appears; remove it and it disappears. Listening
progress goes back to the server on pause over Bluetooth and on sync over
Wi-Fi.

Why a proxy in between: a single `.m4b` on the watch would be one track
spanning twelve hours with no chapter navigation, and Connect IQ aborts large
JSON responses anyway. The reasoning in detail is in
[docs/PLAN.md](docs/PLAN.md).

## Status

| Part | State |
|---|---|
| `abconnect-proxy` | functional, 155 tests green (incl. real ffmpeg cut) |
| Connect IQ app | compiles cleanly, **has never run on hardware** |
| Hardware spike (M0) | **open** — the decisive open question |

The M0 spike is still outstanding: play a stream-copied segment on the
fēnix 7X Pro. If the device rejects such files, the whole approach does not
hold — that belongs before any further work.

## Getting started

```sh
# Proxy: tests
python3 -m venv .venv && .venv/bin/pip install -e './proxy[dev]'
.venv/bin/python -m pytest proxy/tests

# Proxy: install and run -> deploy/README.md
./deploy/install.sh

# Build the app -> app/README.md (URL and token go into the .prg)
PROXY_URL=https://abconnect.example PROXY_TOKEN=... \
CIQ_HOME=/path/to/sdk ./app/build.sh
```

## Requirements

- Audiobookshelf ≥ 2.26 with an API key
- `abconnect-proxy` reachable over HTTPS
- Garmin watch with music storage and Wi-Fi — initial target device fēnix 7X Pro
