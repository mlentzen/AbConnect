# AbConnect

Audiobookshelf as a Connect IQ audio provider for Garmin music watches.

Audiobooks from a self-hosted
[Audiobookshelf](https://www.audiobookshelf.org/) (ABS) instance land on the
watch, play offline through the system media player, and listening progress
goes back to the server.

## How it works

```
Audiobookshelf  <--API key--  abconnect-proxy  <--token--  Garmin watch
   (.m4b)          downloads,     (segments,       Wi-Fi sync / phone BT
                   cuts           JSON, pairing)
```

1. **Selection happens in ABS.** Each user has a playlist (default
   **`Garmin`**). Put a book into it and it ends up on the watch. Take it out
   and it disappears.
2. **The proxy prepares.** It watches the playlist and downloads the `.m4b`.
   It cuts the file losslessly into chapter-wise segments of 10–20 minutes and
   then deletes the source again. The ABS API key never leaves the proxy.
3. **The watch syncs.**
   - The sync runs over Wi-Fi, started from the app menu or automatically while
     the watch charges.
   - It first reports progress, then reads the playlist, downloads missing
     segments and deletes books that were removed.
4. **Progress flows both ways.** The watch buffers positions and sends them on
   pause over the phone connection, on "Sync progress" and on every Wi-Fi sync.
   The proxy reconciles them with ABS; the newer position wins.

Why a proxy at all: a single `.m4b` on the watch would be one twelve-hour track
without chapter navigation, and Connect IQ aborts large JSON responses. The
full reasoning is in [docs/PLAN.md](docs/PLAN.md).

## Repository layout

```
app/        Connect IQ app (Monkey C), type audio-content-provider-app
  source/     AbConnectApp.mc (entry, the four modes), Store/Keys (Object Store),
              Idle, Log, Progress; net/ (proxy client), sync/, playback/, ui/
  resources/  strings (eng, deu), settings, drawables
  build.sh    build script; bakes optional defaults into source/BuildDefaults.mc
proxy/      abconnect-proxy (Python, FastAPI), with tests in proxy/tests
deploy/     Podman quadlet, auto-rebuild units, install.sh
tools/      stub_device.py (substitute device profile for CI), check_segments.py
docs/       PLAN.md: design decisions, constraints, risks
```

Where to read next:
- [proxy/README.md](proxy/README.md): proxy modules, HTTP API, tests
- [deploy/README.md](deploy/README.md): running the proxy (users file, quadlet)
- [app/README.md](app/README.md): app modes, file map, building, settings on the watch

## First-time setup

1. Deploy the proxy and create a token per watch in `users.toml`
   ([deploy/README.md](deploy/README.md)).
2. Build and side-load the app ([app/README.md](app/README.md)). You can bake
   `PROXY_URL` and `PROXY_TOKEN` into the build, but you don't have to.
3. If the build did not include them, set up the connection on the watch under
   **AbConnect → Settings**:
   1. **Proxy URL**: type the host on the watch keyboard. `https://` is added
      automatically.
   2. **Pair with phone**: the watch shows a 6-character code. On the phone,
      open `https://<proxy>/pair`, enter the code and paste the token. The
      watch picks the token up by itself and tests the connection.
4. Add books to the `Garmin` playlist in ABS. Then put the watch on the charger
   with Wi-Fi available, or choose **Download books**.

## Development

```sh
# Proxy
python3 -m venv .venv && .venv/bin/pip install -e './proxy[dev]'
.venv/bin/python -m pytest proxy/tests      # needs ffmpeg for the media tests

# App (Connect IQ SDK + developer key; see app/README.md)
CIQ_HOME=/path/to/sdk ./app/build.sh
```

CI (`.github/workflows/build.yml`) runs on every push and pull request:

| Job | What it does |
|---|---|
| `lint` | `ruff check` over `proxy/` and `tools/` (config in `proxy/pyproject.toml`) |
| `proxy` | the proxy tests, with ffmpeg |
| `app` | compiles the app against a substitute device profile; the `.prg` is attached to the run as artifact **`abconnect-prg`** (Actions → run → Artifacts) |
| `image` | builds `proxy/Containerfile`; pushes `ghcr.io/<owner>/abconnect-proxy` from the default branch (`latest`) and `v*` tags (version) |

The CI `.prg` contains no proxy URL or token; set both up on the watch. Each
run signs the app with a throwaway key unless the repository secret
`CIQ_DEVELOPER_KEY` holds one (`base64 -w0 developer_key`). With a throwaway
key, a new build may not install over an older one, so delete the app from the
watch first.

## Status

| Part | State |
|---|---|
| `abconnect-proxy` | functional, tests green (incl. real ffmpeg cut) |
| Connect IQ app | compiles cleanly (SDK 9.2, type check level 2), starts on the fēnix 7X Pro |
| Not yet verified on hardware | full sync and playback, pairing and the watch keyboard, sync on the charger, idle close |

## Requirements

- Audiobookshelf ≥ 2.26 with an API key
- `abconnect-proxy` reachable over HTTPS
- Garmin watch with music storage and Wi-Fi (initial target device: fēnix 7X Pro)
