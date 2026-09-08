# Running abconnect-proxy

## 1. Create the secrets

The ABS API key is created in the Audiobookshelf web interface under
*Settings → Users → API Keys*. The second token is freely chosen and protects
the watch → proxy path; it is entered into the watch's app settings later.

```sh
printf '%s' 'abs-api-key-here' | podman secret create abs-api-key -
openssl rand -hex 24 | tee /dev/tty | podman secret create abconnect-token -
```

## 2. Install the units

Adjust `ABS_URL` in `deploy/abconnect-proxy.container` to your own instance,
then:

```sh
./deploy/install.sh
```

The script drops four units and starts the service. No manual build needed: the
image is produced on first start from `proxy/Containerfile`.

| Unit | Location | Purpose |
|---|---|---|
| `abconnect-proxy.build` | `~/.config/containers/systemd/` | builds the image from the checkout |
| `abconnect-proxy.container` | `~/.config/containers/systemd/` | the service itself |
| `abconnect-proxy-rebuild.path` | `~/.config/systemd/user/` | watches the branch tip |
| `abconnect-proxy-rebuild.service` | `~/.config/systemd/user/` | rebuilds and restarts |

Two lines are machine-dependent — the build context and the watched ref file.
The script fills both in from the actual location of the checkout and the
checked-out branch; the repo only holds default values. So after a branch
switch or a moved checkout, just run it again.

## 3. Automatic rebuild

`abconnect-proxy-rebuild.path` watches `.git/refs/heads/<branch>`. Every commit,
`git pull` or checkout on this branch triggers a rebuild and a restart of the
container — not already the saving of a file, so a half-finished state is not
shipped.

Trigger by hand without waiting for a commit:

```sh
systemctl --user start abconnect-proxy-rebuild
```

Check what happened:

```sh
systemctl --user status abconnect-proxy-rebuild.path
journalctl --user -u abconnect-proxy-build -n 50
```

Two things that may stand out:

* A failed build takes the container down with it, because the container pulls
  in the build service via `Requires=`. A broken commit therefore stops the
  service instead of quietly keeping the old image running. If you want it
  otherwise, replace `Requires=` with `Wants=` in `abconnect-proxy.container`.
* `git gc` or `git pack-refs` can remove the watched ref file. The watcher
  recovers as soon as it reappears; a commit right afterwards can slip through
  though. Then the manual call helps.

## 4. Check

```sh
curl -s localhost:18543/health | python3 -m json.tool
```

The service listens on 8080 inside the container, but is published as
`127.0.0.1:18543` — 8080 is already taken on this machine. The healthcheck
inside the container still checks 8080; only the host side changes.

`audiobookshelf: "ok"` means: the address is correct and the API key is
accepted. `playlist_found: true` means the playlist was found under its name —
if it says `false`, the proxy mirrors nothing but also deletes nothing.
Anything else is a misconfiguration that surfaces here instead of only on the
watch's first sync.

## The playlist

What should end up on the watch is decided in Audiobookshelf: create a playlist
named `Garmin` and add books to it. The proxy prepares new entries on its own
and releases removed ones again; the watch mirrors that on the next sync.

If there is no playlist of that name, `/health` reports it as
`playlist_found: false` and `/v1/playlist` answers with 409. The watch then
deletes nothing — a typo in the name does not wipe it.

Check by hand or trigger a single book — the watch no longer calls the
endpoints below `/v1/playlist`, but they are there for debugging:

```sh
TOKEN=$(podman secret inspect --showsecret abconnect-token | python3 -c 'import json,sys;print(json.load(sys.stdin)[0]["SecretData"])')
curl -s -H "Authorization: Bearer $TOKEN" localhost:18543/v1/playlist | python3 -m json.tool
curl -s -H "Authorization: Bearer $TOKEN" localhost:18543/v1/books | python3 -m json.tool
curl -s -X POST -H "Authorization: Bearer $TOKEN" localhost:18543/v1/books/<ID>/prepare
curl -s -H "Authorization: Bearer $TOKEN" localhost:18543/v1/books/<ID>/status
curl -s -H "Authorization: Bearer $TOKEN" localhost:18543/v1/books/<ID>/segments | python3 -m json.tool
```

## Configuration

| Variable | Required | Default | Meaning |
|---|---|---|---|
| `ABS_URL` | yes | — | base URL of the ABS instance |
| `ABS_API_KEY` | yes | — | ABS API key |
| `ABCONNECT_TOKEN` | yes | — | token for the watch; comma list for rotation |
| `ABS_PLAYLIST` | — | `Garmin` | playlist that is mirrored to the watch |
| `PLAYLIST_POLL_SECONDS` | — | 600 | interval of the background reconciliation |
| `CACHE_DIR` | — | `/var/cache/abconnect` | segments and covers |
| `WORK_DIR` | — | `/var/tmp/abconnect` | source file during the prepare job |
| `CACHE_MAX_BYTES` | — | 200 GiB | emergency brake for eviction |
| `RELEASE_TTL_DAYS` | — | 30 | how long released books stay around |
| `SEGMENT_TARGET_SECONDS` | — | 900 | target size of a segment |
| `SEGMENT_MIN_SECONDS` | — | 180 | below this, segments are merged |
| `SEGMENT_MAX_SECONDS` | — | 1500 | above this, segments are split |
| `COVER_URL_TTL_SECONDS` | — | 21600 | validity of the signed cover URLs |
| `TRANSCODE_MODE` | — | `auto` | `auto` re-encodes only what the watch will not play, `always` everything, `never` nothing |
| `TRANSCODE_TARGET` | — | `mp3` | container for re-encoded segments; `m4a` keeps the original container |
| `TRANSCODE_BITRATE_KBPS` | — | 64 | bitrate of a re-encoded segment |
| `LOG_LEVEL` | — | INFO | |

`auto` probes every source file after download and resamples anything that
is not AAC-LC or MP3 at 44100/48000 Hz. Audiobooks at 22050 Hz download
fine but stay silent on the watch, which is what this exists for. A
re-encoded segment roughly doubles in size, so a slow Bluetooth sync is
the price; `TRANSCODE_BITRATE_KBPS=48` buys some of it back.

Changing either setting only affects books prepared afterwards, and a book that
is already `ready` keeps the segments it was first cut with — the cache outlives
the container, and `release` only unpins it. Force the re-cut:

    curl -X POST -H "Authorization: Bearer $ABCONNECT_TOKEN" \
         "$PROXY_URL/v1/books/<book-id>/prepare?force=true"

Then reset the watch before syncing — the sync compares segments by index alone
and would otherwise keep the copies it already has.

## Rotating the token without locking out the watch

`ABCONNECT_TOKEN` accepts a comma list. Prepend the new token, restart the
service, enter it in the watch's app settings, then remove the old one from the
list.
