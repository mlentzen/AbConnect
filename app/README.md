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
| `ui/PlaybackConfigView.mc` | playback configuration: which book |
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
PROXY_TOKEN=$ABCONNECT_TOKEN \
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
| `PROXY_TOKEN` | effectively yes | empty | the proxy's `ABCONNECT_TOKEN` |
| `DELETE_FINISHED` | — | `false` | remove finished books from the watch |

Without the two values the script still builds, but warns: the app then reports
*"Settings needed"* on the watch. The settings page is kept and overrides the
defaults, should the app ever be installed from the Connect IQ store.

**The finished `.prg` therefore contains the token** — do not share it.

## On the watch

The app starts in four modes, and the entry point is not the one you would
expect. Opening the provider directly lands you in playback configuration and
shows "No book on the watch yet" as long as nothing has been downloaded. The
download path is what leads to **book selection**:

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
- Type check level 3 (strict): 27 messages, all about generic type parameters
  of `Storage`, `Dictionary` and `Method`.
- The launcher icon is a transparent placeholder.
- The playlist view shows up to 100 books without paging.
- The progress push on pause is untested: whether the watch holds a phone
  connection at all during playback will only be shown by hardware.
