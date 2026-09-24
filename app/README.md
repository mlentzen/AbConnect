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
| `AbConnectApp.mc` | entry point: hands each mode its view or delegate |
| `ui/SyncConfigView.mc` | sync configuration: shows the playlist and its state |
| `sync/SyncDelegate.mc` | sync: report progress, read the playlist, mirror it |
| `ui/PlaybackConfigView.mc`, `MainMenu.mc`, `BookMenu.mc`, `ChapterMenu.mc`, `InfoView.mc` | playback configuration: the app menu |
| `ui/SettingsMenu.mc`, `PairView.mc` | settings on the watch: proxy URL, pairing, auto sync |
| `ui/ProgressPush.mc` | progress sync over the phone, used from the menus |
| `playback/ContentDelegate.mc`, `ContentIterator.mc` | playback |

Shared across modes:

| File | Purpose |
|---|---|
| `Store.mc`, `Keys.mc` | Object Store access and key layout (flat values, 8 KB each) |
| `net/ProxyClient.mc` | every HTTP call to the proxy, config precedence |
| `Progress.mc` | settles the proxy's answer to a progress push |
| `Idle.mc` | ends the configuration modes after 2 min without input |
| `Log.mc`, `Version.mc` | logging with a build-time level, version constant |

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
CIQ_HOME=/path/to/sdk ./build.sh             # set up URL and token on the watch
PROXY_URL=https://abconnect.example \
PROXY_TOKEN=<token from users.toml> \
CIQ_HOME=/path/to/sdk ./build.sh             # or bake them in
```

You need the Connect IQ SDK, a developer key (`CIQ_KEY`, default
`~/.ciq/developer_key`) and a device profile for `fenix7xpro`.

`build.sh` reads a `.env` next to the script. If it contains `PROXY_URL` and
`PROXY_TOKEN`, they end up as `source/BuildDefaults.mc` in the build and the app
runs without further setup. The file is regenerated on every build and is not
checked in, because it contains the token. Values entered on the watch take
precedence (see below).

The real device profiles are only downloaded by the SDK Manager after a Garmin
login. If you do not have that, `python3 ../tools/stub_device.py` can create a
**substitute profile**. It lets you compile and type-check — but such a build
says nothing about memory limits, layout and behavior on the watch.

### Where URL and token come from

Side-loaded Connect IQ apps get **no** settings page in Garmin Connect.
`ProxyClient.readSetting()` therefore checks three sources, in this order:

1. **The watch.** Values entered under *Settings* (keyboard or pairing) are
   stored in the Object Store. They survive *Reset everything* and schema
   changes.
2. **Phone settings** (`resources/settings/`). Garmin Connect only shows these
   for apps installed from the Connect IQ store.
3. **Build defaults.** `build.sh` writes `PROXY_URL`/`PROXY_TOKEN` from the
   environment or `app/.env` into `source/BuildDefaults.mc`. That file is
   generated and git-ignored.

| Variable | Default | Meaning |
|---|---|---|
| `PROXY_URL` | empty | base URL of the proxy |
| `PROXY_TOKEN` | empty | this watch's token from the proxy's `users.toml` |
| `LOG_LEVEL` | `0` | 0 errors, 1 warnings, 2 course of events, 3 everything |

Without URL and token the build still succeeds, but warns. The app then opens
*Settings* in place of the playlist. **A `.prg` built with `PROXY_TOKEN`
contains the token**, so do not share it.

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
├─ Reset everything media cache and store, after a confirmation (keeps the settings)
├─ Settings
│  ├─ Proxy URL        watch keyboard; "https://" is added to a bare host
│  ├─ Pair with phone  shows a code; enter it with the token at https://<proxy>/pair
│  ├─ Token (manual)   watch keyboard, the fallback
│  ├─ Test connection  GET /v1/status
│  └─ Sync on charger  toggle, on by default
└─ Info             version, commit, build date, and what is on the watch
```

### Pairing

The token is too long to type on five buttons. Pairing lets you enter it on the
phone instead:

1. The watch calls `POST /pair/start` and shows the code together with
   `<host>/pair`.
2. On the phone, the page takes the code and the token.
3. The watch polls `GET /pair/<code>` every 3 s. The token is handed out once.
4. The watch stores the token and checks it with `/v1/status`.

A code expires after 10 minutes. The proxy only accepts a token that is already
valid, so pairing grants nothing new. The server side is in
`proxy/abconnect_proxy/pairing.py`.

### Idle close

The app menu is a normal app on screen. `Idle` ends it with `System.exit()`
after **2 minutes** without input. Every input delegate and every shown view
resets the clock. Work that runs without input holds the clock while it runs:
a progress push, a pairing that waits for the phone, a watch-keyboard entry.
The sync and the system player are not affected.

A sync starts in one of two ways (`AbSyncDelegate.isSyncNeeded()`):

- **By hand.** *Download books* and the system's sync configuration each stamp
  a ticket that stays valid for two minutes. A manual trigger must be answered
  with yes. Otherwise the system skips `onStartSync()` and the sync screen
  freezes at 0 %.
- **On the charger.** When the system asks on its own schedule, the answer is
  yes only if all of these hold:
  - the watch is charging
  - *Sync on charger* is on
  - the app is configured
  - the playlist was last read more than 6 hours ago

  This works like the automatic sync of Spotify and co. Switch it off in
  *Settings* to allow manual syncs only.

The Info screen shows how long ago the playlist was last read.

The other way in is the system's own sync configuration, which is what shows the
playlist and the state of each book on the server:

1. On any page, press and hold **DOWN** (music functions)
2. Press and hold **MENU**
3. **Music providers**
4. **AbConnect**
5. Check the books
6. **BACK** until the watch prompts for synchronization

Downloading happens over Wi-Fi, ideally on the charger.

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
- Not yet run on hardware:
  - pairing and the watch keyboard (`TextPicker`)
  - the idle exit
  - whether the system asks `isSyncNeeded()` while the watch charges on Wi-Fi
