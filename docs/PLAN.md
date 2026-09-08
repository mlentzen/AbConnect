# AbConnect — Audiobookshelf as a Connect IQ audio provider

Planning document. As of: 2026-09-08.

> **Implementation status:** proxy and app are built; the playlist mirroring and
> the progress push on pause work. The hardware spike from M0 is outstanding
> and remains the decisive open question — see R1.

Goal: a Monkey C app of type `audio-content-provider-app` that syncs audiobooks
from a self-hosted [Audiobookshelf](https://www.audiobookshelf.org/) instance
to the Garmin watch, plays them offline and writes listening progress back.

**Target environment (fixed):**

* Current ABS version (≥ 2.26, API keys available)
* Library predominantly single-file `.m4b` **with** chapter markers
* Test device fēnix 7X Pro (`fenix7xpro`, API level 5.2)
* HTTPS with valid certificates is a given
* The target is the Audiobookshelf **playlist "Garmin"**, not a selection on
  the watch
* Companion server runs as a **Podman quadlet** in the existing stack —
  **without a shared filesystem with ABS** and **without a compiled-in server
  address or key**

---

## 1. Constraints

### 1.1 How an audio content provider works

Connect IQ starts the app in **four separate modes** (each mode is its own app
start, there is no shared runtime state):

| Mode | Entry point | Task |
|---|---|---|
| Sync configuration | `getSyncConfigurationView()` | user selects what should be downloaded |
| Sync | `getSyncDelegate()` | system enables Wi-Fi, app downloads files |
| Playback configuration | `getPlaybackConfigurationView()` | user selects what is played |
| Playback | `getContentDelegate()` | system media player plays, app supplies iterator + events |

App class inherits from `Application.AudioContentProviderApp`. Manifest:
`type="audio-content-provider-app"`, permission `Communications`.

Reference implementation: `garmin/connectiq-apps` → `audio-provider/monkeymusic`.

### 1.2 Hard platform constraints

1. **No streaming.** The media player only plays files that were previously
   written into the encrypted media cache via
   `Communications.makeWebRequest(..., {:responseType => HTTP_RESPONSE_CONTENT_TYPE_AUDIO,
   :mediaEncoding => ...})`.
   AbConnect is a download app, not a streaming client.
2. **Codecs:** only `ENCODING_MP3`, `ENCODING_M4A`, `ENCODING_WAV`, `ENCODING_ADTS`.
   No Opus, no FLAC, no HLS.
3. **JSON responses are tightly limited.** `makeWebRequest` aborts on large
   responses with `-402` (too large) or `-403` (memory); it gets critical
   already in the low double-digit KB range. An unfiltered ABS library response
   is therefore not processable.
4. **Object Store: 8 KB per value.** Flat maps, short keys, one key per book
   instead of one global structure.
5. **App size** ideally under 128 KB.

TLS is not an issue in this environment — certificates are valid and the device
requirement (chain from a known CA) is met.

### 1.3 Relevant API details (verified in the Toybox docs)

* **`Media.Content(contentRef, contentMetadata)`** — metadata (title, artist,
  album, genre, trackNumber) can be set by app code. We do *not* depend on tags
  in the audio files.
* **`Media.ActiveContent(contentRef, metadata, playbackStartPos)`** — subclass of
  `Media.Content` with a start position in seconds. Enables real resume in the
  middle of a segment: the `ContentIterator` returns an `ActiveContent` with a
  stored position for the current track.
* **`PlaybackProfile.skipForwardTimeDelta` / `skipBackwardTimeDelta`** — default 30 s,
  set to 30 s forward / 15 s back for audiobooks.

Also: `Media.setAlbumArt()`, `Media.getCacheStatistics()`,
`Media.deleteCachedItem(ref)`, `Media.resetContentCache()`.

`Media.SyncDelegate` is deprecated (removal after System 9). Since the fēnix 7X Pro
offers API level 5.2, we set `minSdkVersion` to 5.0 and implement exclusively
against **`Communications.SyncDelegate`** (from API 3.1.0).

### 1.4 Audiobookshelf API

Auth: **API key** (ABS ≥ 2.26), header `Authorization: Bearer <key>`. Created
under Settings → Users → API Keys, inherits the rights of the assigned user.
The key lives exclusively in the proxy, never on the watch.

Endpoints used (by the proxy, not the watch):

| Purpose | Endpoint |
|---|---|
| Libraries | `GET /api/libraries` |
| Book list | `GET /api/libraries/{id}/items?limit&page&sort&minified=1` |
| Book details incl. `media.audioFiles[]`, `media.chapters[]` | `GET /api/items/{id}?expanded=1&include=progress` |
| Books in progress | `GET /api/me/items-in-progress` |
| **File download** | `GET /api/items/{id}/file/{ino}/download` |
| Cover | `GET /api/items/{id}/cover?width=...&format=jpeg` |
| Write / read progress | `PATCH` or `GET /api/me/progress/{libraryItemId}` |

> Exact paths and field names are to be verified against the target instance —
> ABS reworked auth and sessions in 2.26. A smoke-test script is part of M1.

Deliberately **not** used: `POST /api/items/{id}/play` and the session/HLS
endpoints. Those deliver transcoding streams the device cannot play.

---

## 2. Central design decisions

### E1 — `abconnect-proxy` is a core component

A single-file `.m4b` is not directly usable on the watch: one track spanning
twelve hours, no chapter navigation, a single download of several hundred MB
whose abort costs everything. Since the library consists predominantly of
`.m4b`, the proxy is a prerequisite, not an accessory.

It solves three problems at once:

1. **Chapter cutting.** `ffmpeg -ss <start> -to <end> -i book.m4b -map_chapters -1 -c copy seg.m4a`
   cuts losslessly via stream copy — no re-encode, the result is AAC in an MP4
   container and therefore `ENCODING_M4A`.
2. **Lean JSON responses.** The watch never sees an ABS response, only flat,
   reduced lists (see 1.2.3).
3. **Secrets stay server-side.** The ABS API key lives in the proxy; the watch
   only knows the proxy URL and a token of its own.

### E2 — Preparation per book, not per segment

The proxy has **no access to the ABS media directory**. To cut, it first has to
fetch the `.m4b` via `GET /api/items/{id}/file/{ino}/download`. This rules out
cutting within the request — otherwise every single segment would trigger a
300 MB download.

Instead, a **prepare job per book**:

```
prepare(bookId):
  1. fetch metadata + chapters from ABS
  2. download .m4b to WORK_DIR
  3. ffprobe: verify chapters (fallback: 15-minute grid)
  4. normalize segment table
  5. cut all segments via -c copy -> CACHE_DIR/<bookId>/
  6. fetch and downscale cover
  7. delete .m4b            <- immediately, not at job end
  8. status = ready
```

The job is triggered **when checking a book in the sync configuration**, not on
sync. By the time the watch syncs on the charger, the book is finished as a
rule. The sync only queries the status and downloads what is `ready`; anything
else it reports as "still being prepared" instead of blocking.

Step 7 is deliberately early: after the cut, the proxy only holds the segments,
whose total size thanks to stream copy roughly matches the source file. The
peak usage of ~2× book size exists only during the job.

### E2a — The playlist is the target

Selection happens in Audiobookshelf, not on the watch: whatever is in the
playlist `ABS_PLAYLIST` (default `Garmin`) belongs on the watch. If a book is
added, it appears; if it is removed, it disappears. That spares selection on a
280-pixel display and makes the phone the only place where decisions are made.

The proxy reconciles on its own (`PLAYLIST_POLL_SECONDS`, default 600) so a
freshly added book is already segmented and ready before the watch syncs the
next time. The watch reads the target via `GET /v1/playlist` and mirrors it:
download missing segments, delete surplus books.

**A failure is not an empty playlist.** A typo in the name, a briefly
unreachable ABS, an HTTP error — none of that may wipe the watch. The proxy
answers `/v1/playlist` with 409 instead of an empty list, releases nothing
during reconciliation and keeps reporting the last known state; the watch only
deletes when it has a fresh, valid target in hand.

The watch remembers the last known state and when it fetched it. Without this
timestamp a newly added book would go unnoticed: everything is fine locally,
there would be no reason to sync. That is why a target is considered stale
after `PLAYLIST_MAX_AGE_SECONDS` (6 h) and triggers a sync.

The endpoints `/v1/books`, `/prepare` and `/release` still exist, but the watch
no longer calls them — they are tools for `curl` and debugging.

### E3 — Configuration exclusively at runtime

The image contains **no** ABS address and no key. Everything comes from the
environment, secrets via Podman secrets:

| Variable | Required | Meaning |
|---|---|---|
| `ABS_URL` | yes | base URL of the ABS instance (reachable within the stack) |
| `ABS_API_KEY` | yes | ABS API key, mounted as a Podman secret |
| `ABS_PLAYLIST` | — | name of the authoritative playlist, default `Garmin` |
| `PLAYLIST_POLL_SECONDS` | — | interval of the background reconciliation, default 600 |
| `ABCONNECT_TOKEN` | yes | token for watch → proxy, independent of the ABS key; comma list for rotation |
| `CACHE_DIR` | — | segment cache, default `/var/cache/abconnect` |
| `WORK_DIR` | — | transient space for the `.m4b` during the job |
| `CACHE_MAX_BYTES` | — | upper limit, above which LRU eviction kicks in; set generously |
| `RELEASE_TTL_DAYS` | — | how long released books stay in the cache, default 30 |
| `SEGMENT_TARGET_SECONDS` / `_MIN_` / `_MAX_` | — | segment normalization, default 900 / 180 / 1500 |
| `LOG_LEVEL` | — | |

The start aborts with a clear message if a required variable is missing — no
silent operation with defaults. `GET /health` additionally checks whether ABS
is reachable and the key is accepted; this way a misconfiguration surfaces in
the quadlet healthcheck, not only on the watch's first sync.

Example quadlet (`~/.config/containers/systemd/abconnect-proxy.container`):

```ini
[Unit]
Description=AbConnect proxy
After=audiobookshelf.service

[Container]
Image=ghcr.io/mlentzen/abconnect-proxy:latest
Environment=ABS_URL=https://audiobookshelf.internal
Secret=abs-api-key,type=env,target=ABS_API_KEY
Secret=abconnect-token,type=env,target=ABCONNECT_TOKEN
Volume=abconnect-cache:/var/cache/abconnect
Volume=abconnect-work:/var/tmp/abconnect
PublishPort=127.0.0.1:18543:8080   # 8080 is taken on the host
HealthCmd=/usr/bin/curl -fsS http://localhost:8080/health

[Install]
WantedBy=default.target
```

### E4 — Segment normalization

Chapter markers are present, but ABS chapters vary widely in length. Target
size 10–20 min: chapters under 3 min are merged with the following chapter,
chapters over 25 min are split at a fixed grid (part 1/2/…). If chapter markers
are missing or unusable (times outside the duration, not monotonic, only one
chapter across the whole book), the **fallback: a plain 15-minute grid** kicks
in. At 64 kbps this gives ~5–10 MB per segment — small enough that an abort is
cheap and the unknown `makeWebRequest` file limit does not apply.

### E5 — One segment = one "song"

Each segment becomes a track, the book is the "album", the author the "artist",
the segment index the `trackNumber`. Next/previous, progress display and resume
work with that without special logic.

The watch **never** computes in absolute book times. It only knows
`(segment index, offset within the segment)`; the conversion into ABS
`currentTime` is done by the proxy using the segment table. That keeps the
device logic small and the segmentation changeable server-side.

### E6 — Progress buffered, with two ways out

`ContentDelegate.onSong()` delivers `(refId, event, playbackPosition)`; from
that `(bookId, segIdx, sec, ts)` is written flat into the Object Store. From
there it goes out in two ways:

1. **On pause over Bluetooth.** Pause and stop are the only moments during
   playback when a radio access disturbs nobody. If the phone is connected
   (`DeviceSettings.phoneConnected`), the buffer moves to `POST /v1/progress`
   immediately. Throttled to one attempt per 30 seconds, because pause and
   resume come in series.
2. **On sync over Wi-Fi**, as the first step before all downloads.

Both ways send the same data and only discard the buffer after confirmed
acceptance — if one fails, the other catches up. Conversely, a position
listened further on the phone comes back to the watch on both ways. Conflict
rule: **the more recent timestamp wins**.

### E7 — Sync is delta-based and abort-resistant

The Object Store holds the local inventory. The sync computes `toDownload` /
`toDelete` from the selection. An abort loses only the current segment, not the
book. Option "automatically delete finished books".

### E8 — Multi-file books run along without a special path

Books that already exist in ABS as multiple MP3/M4A files are handled
identically by the proxy: prepare downloads the files, the segment table
matches the existing files, cutting only happens when a file exceeds
`SEGMENT_MAX`.

---

## 3. Architecture

```
proxy/                       abconnect-proxy (Python/FastAPI + ffmpeg, Podman)
  config.py                  env validation at start, no defaults for secrets
  abs_client.py              ABS REST with API key, metadata cache
  segmenter.py               chapters -> normalized segment table, 15-min fallback
  preparer.py                job: download -> ffprobe -> cut -> delete m4b -> ready
  cache.py                   CACHE_DIR management, pinning, release TTL, LRU as emergency brake
  auth.py                    bearer check (constant-time), signed cover URLs
  api.py                     /v1/* contract to the watch, /health
  progress.py                segment offset <-> absolute book time, push to ABS

source/                      Connect IQ app (Monkey C)
  AbConnectApp.mc            AudioContentProviderApp: the four delegates/views
  Constants.mc               property keys, enums, schema version

  net/
    ProxyClient.mc           /v1 calls, token header
    RequestQueue.mc          serial request chain + context injection

  sync/
    SyncDelegate.mc          Communications.SyncDelegate
    SyncPlanner.mc           delta selection vs. local inventory, status filter
    Downloader.mc            makeWebRequest with :mediaEncoding, retry, progress

  ui/
    SyncConfigView.mc        book list (CheckboxMenu), triggers prepare, shows status
    PlaybackConfigView.mc    local books, "resume" / "from the start"
    ProgressView.mc
    ErrorView.mc

  playback/
    ContentDelegate.mc       supply iterator, onSong -> progress buffer
    ContentIterator.mc       order, metadata, ActiveContent with start position
    ProgressStore.mc         flat buffer + flush API

resources/                   strings (de/en), icons, settings.xml (proxyUrl, proxyToken)
manifest.xml                 type=audio-content-provider-app, fenix7xpro, minSdkVersion 5.0
monkey.jungle
deploy/                      quadlet unit, example secrets, setup docs
```

### Proxy API (contract to the watch)

| Endpoint | Purpose |
|---|---|
| `GET /v1/playlist` | **the target**: books of the playlist with state; 409 if the playlist is missing |
| `GET /v1/books?page=&q=` | browse the library (tool, not used by the watch) |
| `POST /v1/books/{id}/prepare` | trigger the job (idempotent), response immediately |
| `GET /v1/books/{id}/status` | `pending` \| `preparing` (+ percent) \| `ready` \| `error` (+ reason) |
| `GET /v1/books/{id}/segments` | segment list: index, title, duration, bytes — only when `ready` |
| `GET /v1/books/{id}/seg/{n}.m4a` | finished segment from the cache |
| `GET /v1/books/{id}/cover.jpg?w=&exp=&sig=` | downscaled cover, pre-signed URL (see Auth) |
| `POST /v1/books/{id}/release` | watch reports: book no longer needed → cache may evict |
| `POST /v1/progress` | batch upload, conversion to book time, forwarding to ABS |
| `GET /health` | configuration + ABS reachability |

### Auth between watch and proxy

All `/v1` endpoints require `Authorization: Bearer <ABCONNECT_TOKEN>`. That is
the only protection of this path — TLS provides confidentiality, the token
provides access control.

**What it does:** It prevents an arbitrary caller from reading the library,
triggering prepare jobs (CPU and disk load) or writing someone else's listening
progress to ABS via `/v1/progress`. Above all it separates the trust levels:
the ABS API key stays in the proxy, the watch never knows it. A compromised
token can be rotated without touching ABS, and its damage ends at the `/v1`
surface.

**What it does not do:** It is a shared secret, not an identity. There is no
distinction between individual devices and no session. On the watch it lives as
plain text in the Connect IQ app settings and runs through Garmin Connect —
usable as an access barrier for a private stack, no substitute for an auth
system with users.

Implementation:

* Comparison with `hmac.compare_digest`, not with `==`.
* `ABCONNECT_TOKEN` accepts a comma list so a new token can be set before the
  old one disappears from the watch settings.
* Backoff after repeatedly failed auth so the endpoint does not become a
  guessing oracle.
* No token in URLs (see below) — reverse-proxy logs record query strings.

**Exception: cover.** `Communications.makeImageRequest` does **not** support
`:headers` (unlike `makeWebRequest`, which allows `:headers` even together with
`:responseType => HTTP_RESPONSE_CONTENT_TYPE_AUDIO`). So the cover cannot send
the bearer header. Instead of appending the token as a query parameter,
`/v1/books/{id}/segments` delivers a **pre-signed cover URL**:
`?exp=<unix-ts>&sig=<HMAC(token, bookId|exp)>`, valid for a few hours. The
watch uses the URL unchanged; the long-lived token never ends up in a log
file. All other downloads go through `makeWebRequest` and thus through the
header.

### Data flow

```
ABS  <--API key, HTTPS--  abconnect-proxy  <--token, HTTPS--  fenix 7X Pro
        (download of the m4b)                (segments)

Sync config:   GET  /v1/books                  -> CheckboxMenu -> Store: SEL
               POST /v1/books/{id}/prepare     -> job runs in the background
Sync:          GET  /v1/books/{id}/status      -> only ready is downloaded
               GET  /v1/books/{id}/segments    -> delta against local inventory
               GET  /v1/books/{id}/seg/{n}.m4a -> media cache (ENCODING_M4A)
               GET  /v1/books/{id}/cover.jpg   -> makeImageRequest
               POST /v1/progress               <- Store: PRG  -> ABS /api/me/progress
               POST /v1/books/{id}/release     -> for deselected books
Playback:      Store -> ContentIterator -> ActiveContent(ref, meta, startPos)
               onSong(pos) -> Store: PRG
```

### Cache housekeeping in the proxy

* `CACHE_DIR/<bookId>/` holds segments + cover, size ≈ source file.
* `WORK_DIR` holds the `.m4b` only during the job; deletion right after the cut,
  even on error (`try/finally`).
* Books in the watch's current selection are **pinned** and are not evicted;
  `release` lifts the pin.
* Disk space is plentiful in this environment, `CACHE_MAX_BYTES` is set
  accordingly high. Released books therefore stay around for
  `RELEASE_TTL_DAYS` — a re-checked book is then immediately `ready`, without a
  second download and cut. That is the actual benefit of the large cache.
* LRU against `CACHE_MAX_BYTES` remains as a safety net, not as routine
  operation. An evicted book goes back to `pending` and is re-prepared when
  needed.
* Before starting a job it is still checked whether source size + segments fit;
  otherwise `error` with a clear message instead of a full disk.

### Object Store layout on the watch (8 KB limit per value)

| Key | Content |
|---|---|
| `SEL` | array of selected book IDs |
| `LOC_<bookId>` | flat map `refId -> "segIdx\|duration"` — **one key per book** |
| `BOOK_<bookId>` | title, author, segment count, cover status (short strings) |
| `PRG` | flat map `bookId -> "segIdx\|sec\|ts"`, only for locally present books |
| `VER` | schema version → on mismatch `clearProperties()` + `resetContentCache()` |

---

## 4. Risks

| # | Risk | Effect | Mitigation |
|---|---|---|---|
| R1 | ffmpeg stream copy produces a file the watch rejects | approach collapses entirely | **Spike in M0** before anything else: cut a segment by hand and play it on the fēnix |
| R2 | prepare job takes longer than the patience during sync | book missing at sync | triggered already on check (E2); sync shows status instead of blocking |
| R3 | volume fills up despite plenty of space (misconfiguration, WORK_DIR leftovers) | job fails | pre-check; delete `.m4b` in `finally`; LRU as a safety net; `/health` reports cache fill level |
| R4 | network load ABS → proxy on every prepare | slow for large books | once per book instead of per segment; backlog: `ffmpeg` via HTTP range directly against the ABS URL, if range is reliably supported |
| R5 | chapter markers unusable after all (not monotonic, outside the duration) | wrong segment boundaries | validation in `segmenter.py`, automatic 15-min fallback, report in M1 |
| R6 | unknown `makeWebRequest` file limit | sync aborts on hardware, not in the simulator | 5–10 MB segments stay well below it; determine the limit in the M0 spike |
| R7 | 8 KB property limit with a large library | data loss/crash | key-per-book layout; serialization test with 500 books |
| R8 | ABS API changes (2.26 auth rework) | proxy breaks | version check at start, `/health`, smoke test in the repo |
| R9a | playlist unfindable or ABS briefly gone | watch could be wiped | a failure never means "empty": 409 instead of an empty list, no releasing during reconciliation, watch only deletes with a fresh target; `/health` reports `playlist_found` |
| R9 | fēnix 7 Pro **without a Wi-Fi** variant | sync over BLE impractically slow | only support Wi-Fi variants, mention it in the description |
| R10 | `ABCONNECT_TOKEN` is a shared secret in plain text on the watch | no per-device revocation, token in Garmin Connect | deliberately accepted for a private stack; rotation via comma list, pre-signed cover URLs instead of a token in the query string |
| R11 | store approval for audio provider apps | release delayed | check review requirements early, document the sideload path |

---

## 5. Roadmap

**M0 — feasibility spike (first, small, decides everything)** — *app skeleton stands, spike open*
Cut a book from the real library by hand with ffmpeg `-c copy`, serve it via a
mini HTTP server, load and play it with a throwaway app on the fēnix 7X Pro.
Answers R1 and R6 before code is written. In parallel: app skeleton with all
four delegates as stubs, build for `fenix7xpro` green, CI compiles.

**M1 — `abconnect-proxy` v1** — *implemented*
Env validation and `/health`, ABS client with API key, chapter validation and
segment normalization incl. 15-min fallback, prepare job with download → cut →
immediate deletion of the `.m4b`, cache with LRU and pinning, `/v1/books`,
`/status`, `/segments`, `/seg/{n}.m4a`, `/cover.jpg` with a pre-signed URL,
`/release`, bearer auth with constant-time comparison. Plus a smoke test
against the real instance and a report on the chapter quality of the library
(R5). *Result: `curl` delivers a playable segment, the quadlet runs.*

**M2 — sync configuration and sync**
`settings.xml` (proxyUrl, proxyToken), `ProxyClient`, book list with paging as a
`CheckboxMenu` — checking triggers `prepare`, status is shown.
`Communications.SyncDelegate` with a delta planner and status filter, serial
downloads with `:mediaEncoding => Media.ENCODING_M4A`, `notifySyncProgress` /
`notifySyncComplete`, `deleteCachedItem`, cover via `makeImageRequest`, memory
check via `getCacheStatistics()` before the sync.
*Result: a book is completely on the watch.*

**M3 — playback**
`ContentDelegate` + `ContentIterator`, metadata from the store instead of from
tags, `PlaybackProfile` with audiobook skips (30 s / 15 s), `ActiveContent`
with a start position, playback configuration with "resume" / "from the start".
*Result: segments play in the right order, resume works.*

**M4 — progress bidirectional**
`onSong` buffer, flush to `POST /v1/progress`, conversion in the proxy, read
the server position on sync, conflict rule most recent timestamp, "delete
finished" including `release`. *Result: phone and watch stay in sync.*

**M5 — hardening & release**
Error paths (401, proxy offline, prepare error, storage full, sync abort),
strings de/en, store migration via `VER`, icons, `deploy/` with a quadlet unit,
secret creation and setup docs, store submission or sideload guide.

**Backlog:** more devices beyond `fenix7xpro`, ffmpeg via HTTP range instead of
a full download (R4), optional re-encode to a lower bitrate, podcast support.

---

## 6. Target device and testing

Target device: fēnix 7X Pro (`fenix7xpro`, API level 5.2, 32 GB).
`minSdkVersion` 5.0. More devices only after M5 — each additional one costs
layout and testing effort without a new feature.

Test levels:
1. **Simulator** — functional logic, all four modes.
2. **Proxy tests** — segmentation, chapter validation and cutting against real
   `.m4b` files; fast, automatable, outside of Monkey C.
3. **Hardware** — in play from M0, mandatory from M2: file sizes, memory and
   codec acceptance cannot be validated in the simulator.

---

## 7. Open points

1. Include podcasts from ABS or limit to books?
2. Publish in the Connect IQ store or sideload only?

---

## Sources

* [garmin/connectiq-apps — audio-provider/monkeymusic](https://github.com/garmin/connectiq-apps/tree/master/audio-provider/monkeymusic)
* [Toybox.Media API](https://developer.garmin.com/connect-iq/api-docs/Toybox/Media.html) —
  [Content](https://developer.garmin.com/connect-iq/api-docs/Toybox/Media/Content.html),
  [ActiveContent](https://developer.garmin.com/connect-iq/api-docs/Toybox/Media/ActiveContent.html),
  [ContentIterator](https://developer.garmin.com/connect-iq/api-docs/Toybox/Media/ContentIterator.html),
  [PlaybackProfile](https://developer.garmin.com/connect-iq/api-docs/Toybox/Media/PlaybackProfile.html)
* [Toybox.Communications.SyncDelegate](https://developer.garmin.com/connect-iq/api-docs/Toybox/Communications/SyncDelegate.html)
* [Creating Music Apps in Connect IQ 3](https://www.garmin.com/en-US/blog/developer/creating-music-apps-3x/)
* [Connect IQ Compatible Devices](https://developer.garmin.com/connect-iq/compatible-devices/)
* [Audiobookshelf API Reference](https://api.audiobookshelf.org/) ·
  [API Keys](https://audiobookshelf.org/docs/documentation/server-management/api-keys/)
* [Split M4B losslessly by chapters](https://orsolabs.dev/audiobo/guides/split-m4b-into-chapters/) ·
  [m4b-tool](https://github.com/sandreas/m4b-tool)
* [Podman Quadlet](https://docs.podman.io/en/latest/markdown/podman-systemd.unit.5.html)
```
