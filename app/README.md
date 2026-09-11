# AbConnect (Connect IQ app)

App of type `audio-content-provider-app` for the fēnix 7X Pro. It downloads
audiobook segments from [abconnect-proxy](../proxy/README.md), plays them
through the system media player and remembers the listening progress.

## Structure

Connect IQ starts the app in four separate modes, each as its own app start
without shared runtime state. Anything that has to outlive a mode lives in the
Object Store — flat, because each value there is limited to 8 KB.

| File | Mode |
|---|---|
| `ui/SyncConfigView.mc` | sync configuration: shows the playlist and its state |
| `sync/SyncDelegate.mc` | sync: report progress, read the playlist, mirror it |
| `ui/PlaybackConfigView.mc`, `MainMenu.mc`, `BookMenu.mc`, `ChapterMenu.mc`, `InfoView.mc` | playback configuration: the app menu |
| `playback/ContentDelegate.mc`, `ContentIterator.mc` | playback |

Selection does not happen on the watch but in Audiobookshelf: the playlist
`Garmin` is the target, the sync mirrors it. If the playlist is missing or the
server is unreachable, nothing is deleted.

Two details make this an audiobook app rather than a music app:
`Media.ContentMetadata` is set by hand (the segment titles come from the store,
not from the file's tags), and the current segment is returned as
`Media.ActiveContent` with a start position — only then does the player resume
in the middle of a chapter.

## Building

```sh
PROXY_URL=https://abconnect.example \
PROXY_TOKEN=<this watch's token from users.toml> \
CIQ_HOME=/path/to/sdk ./build.sh
```

You need the Connect IQ SDK, a developer key (`CIQ_KEY`, default
`~/.ciq/developer_key`) and a device profile for `fenix7xpro`.

`build.sh` reads a `.env` next to the script. If it contains `PROXY_URL` and
`PROXY_TOKEN`, they end up as `source/BuildDefaults.mc` in the build and the app
runs without further setup. The file is regenerated on every build and is not
checked in — it contains the token. Whatever is set in the phone app's settings
still takes precedence.

The real device profiles are only downloaded by the SDK Manager after a Garmin
login. If you do not have that, `python3 ../tools/stub_device.py` can create a
**substitute profile**. It lets you compile and type-check — but such a build
says nothing about memory limits, layout and behavior on the watch.

### Why the credentials belong in the build

Side-loaded Connect IQ apps get **no** settings page in Garmin Connect — so the
app on the watch would never see the proxy URL and token. That is why
`build.sh` sets both as default values in the package:
`resources/settings/properties.xml.in` is the template in git, the
`properties.xml` generated from it is in `.gitignore` because it contains the
token.

| Variable | Required | Default | Meaning |
|---|---|---|---|
| `PROXY_URL` | effectively yes | empty | base URL of the proxy |
| `PROXY_TOKEN` | effectively yes | empty | this watch's token from the proxy's `users.toml` |
| `LOG_LEVEL` | — | `0` | 0 errors, 1 warnings, 2 course of events, 3 everything |
| `DELETE_FINISHED` | — | `false` | remove finished books from the watch |

Without the two values the script still builds, but warns: the app then reports
*"Settings needed"* on the watch. The settings page is kept and overrides the
defaults, should the app ever be installed from the Connect IQ store.

**The finished `.prg` therefore contains the token** — do not share it.

### Version

`source/Version.mc` holds `APP_VERSION` and is bumped by hand. `build.sh` adds
the short commit hash (with a `+` when the tree was dirty) and the build date,
which is what actually identifies a build — the version number alone cannot tell
two builds of `0.1.0` apart. All three are on the Info screen.

### Logging

`LOG_LEVEL=0` is the default and prints errors only. Every line costs on the
watch, and the loud paths run per segment and per tick, so the trace is
something you ask for:

```sh
LOG_LEVEL=3 CIQ_HOME=/path/to/sdk ./build.sh
```

Because Monkey C builds a message before it calls the function that would drop
it, the call sites in loops and tickers guard on `Log.LEVEL` themselves rather
than leaving it to `Log`. `probeCache()` in the iterator is skipped entirely
below `DEBUG`: it walks the whole media cache to produce nothing but a trace.

## On the watch

Opening AbConnect from the apps list, or through **Music providers →
AbConnect**, lands on the app menu. Holding **DOWN** opens the watch's music
controls instead, and those always show the now-playing screen of the active
provider — no Connect IQ API changes that. From there the menu is behind the
controls' own menu → **Library**.

```
AbConnect
├─ Continue         the book that was last playing, one press  (only when there is one)
├─ Books            everything playable on the watch → chapters → Resume / From the start
├─ Sync progress    positions both ways over the phone, no Wi-Fi, no sync mode
├─ Download books   Wi-Fi: report progress, read the playlist, mirror it
├─ Reset everything media cache and store, after a confirmation
└─ Info             version, commit, build date, and what is on the watch
```

A sync only ever runs because it was asked for: `isSyncNeeded()` answers yes
only while a manual request is fresh — the Download books row and the system's sync
configuration each stamp one, good for two minutes — so the system never
schedules one of its own. A plain no is not an option: the system then skips
`onStartSync()` and the sync screen freezes at 0 %. The Info screen shows how
long ago the playlist was last read, which is the number to decide on.

The other way in is the system's own sync configuration, which is what shows the
playlist and the state of each book on the server:

1. On any page, press and hold **DOWN** (music functions)
2. Press and hold **MENU**
3. **Music providers**
4. **AbConnect**
5. Check the books
6. **BACK** until the watch prompts for synchronization

Downloading happens over Wi-Fi, sensibly on the charger.

## Status

Compiles cleanly against SDK 9.2 at type-check level 2 (informative). Starts on
the fēnix 7X Pro and is listed there as a music provider; sync and playback
have not yet been run through on hardware.

Open:
- Type check level 3 (strict): 141 messages, of two kinds only — generic type
  parameters of `Storage`, `Dictionary` and `Method`, and "value not available
  in all function scopes" for `WatchUi` names reached through `import`. Level 2
  is clean.
- The playlist view shows up to 100 books without paging.
- The progress push on pause is untested: whether the watch holds a phone
  connection at all during playback will only be shown by hardware.
