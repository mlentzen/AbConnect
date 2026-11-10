# AbConnect (Connect IQ app)

[![build](https://github.com/mlentzen/AbConnect/actions/workflows/build.yml/badge.svg?branch=main)](https://github.com/mlentzen/AbConnect/actions/workflows/build.yml)

App of type `audio-content-provider-app`. It downloads audiobook segments from
[abconnect-proxy](../proxy/README.md), plays them through the system media
player and remembers the listening progress.

> This is my first Garmin Connect IQ application and it has only been tested on a Fenix 7X Pro.
> I expect that there will be certain issues on other devices. Please open an issue if you experience
> any problems.

## Structure

| File | Mode |
|---|---|
| `ui/SyncConfigView.mc` | sync configuration: the playlist and its state |
| `sync/SyncDelegate.mc` | sync: report progress, read the playlist, mirror it |
| `ui/PlaybackConfigView.mc`, `MainMenu.mc`, `BookMenu.mc`, `ChapterMenu.mc`, `InfoView.mc` | playback configuration: the app menu |
| `playback/ContentDelegate.mc`, `ContentIterator.mc` | playback |

Which books land on the watch is decided in Audiobookshelf. The playlist
`Garmin` is the target by default, and a sync mirrors it. If the playlist is missing or
the server is unreachable, nothing is deleted.

Segment titles come from the store, and the current segment is returned as
`Media.ActiveContent` with a start position, so playback can resume in the
middle of a chapter.

## Building

Build the `.prg` yourself.

```sh
CIQ_HOME=/path/to/sdk ./build.sh
```

Build a store `.iq` package:

```sh
EXPORT=1 CIQ_HOME=/path/to/sdk ./build.sh
```

You need the Connect IQ SDK, a developer key (`CIQ_KEY`, default
`~/.ciq/developer_key`) and a device profile for the watch you are building.
`DEVICE` selects it and defaults to `fenix7xpro`.

`build.sh` reads a `.env` next to the script (copy `.env.example`). `PROXY_URL` and `PROXY_TOKEN`
are optional. Left unset, the build uses `https://abconnect.example.com` and
`replace-me`. Enter the real values in the app under **Settings**, or set them
at build time to bake them in. A value stored on the watch overrides the one
from the build. They are written into `source/BuildDefaults.mc`, which is
regenerated on every build and stays out of git, because a build given a real
token contains it. **Do not share a `.prg` built with your token.**

| Variable | Required | Default | Meaning |
|---|---|---|---|
| `PROXY_URL` | - | `https://abconnect.example.com` | base URL of the proxy |
| `PROXY_TOKEN` | - | `replace-me` | this watch's token from the proxy's `users.toml` |
| `LOG_LEVEL` | - | `0` | 0 errors, 1 warnings, 2 course of events, 3 everything |
| `DEVICE` | - | `fenix7xpro` | device id passed to the compiler |
| `EXPORT` | - | `0` | `0` builds one `.prg` for `DEVICE`; `1` exports a store `.iq` for every manifest product (`monkeyc -e -r`) |
| `JUNGLES` | - | `monkey.jungle` | `monkeyc -f` jungles; CI sets `monkey-ci.jungle` (fenix7xpro stub, no device overlays) |

## On the watch

Open AbConnect from the apps list, or from **Music providers → AbConnect**.
The watch's music controls show the now-playing screen of the active provider;
the app menu is the library behind those controls.

```
AbConnect
├─ Continue              the book that was last playing, one press  (only when there is one)
├─ Books                 everything playable on the watch → chapters → Resume / From the start
├─ Sync progress         positions both ways over the phone, no Wi-Fi, no sync mode
├─ Download books        Wi-Fi: report progress, read the playlist, mirror it
├─ Chosen on the server  the playlist and the state of each book
├─ Settings              proxy URL, token, and Reset everything
└─ Info                  version, build date, and what is on the watch
```

A sync runs only when you ask for it, from **Download books** or from the
system sync configuration for this provider (**Music providers → AbConnect**).
The request stays fresh for two minutes; after that a sync waits until you ask
again. The Info screen shows how long ago the playlist was last read.
Downloading uses Wi-Fi and it is recommended to plug in the watch during that time. That same sync
configuration shows the playlist and the state of each book on the server.
