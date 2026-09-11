# Running abconnect-proxy

## 1. Create the users file

One proxy serves any number of people. Each one is an entry in `users.toml`:
their own Audiobookshelf, their API key, their playlist, and the token their
watch sends. The token is the only thing the watch knows — it decides whose
books a request sees.

```toml
[users.manuel]
tokens = ["<token for manuel's watch>"]
abs_url = "https://ab.ml-bn.de"
abs_api_key = "<API key of manuel's ABS account>"
playlist = "Garmin"            # optional, defaults to ABS_PLAYLIST

[users.anna]
tokens = ["<token for anna's watch>"]
abs_url = "https://abs.example.org"
abs_api_key = "<API key of anna's ABS account>"
```

* The ABS API key is created in the Audiobookshelf web interface under
  *Settings → Users → API Keys*. The proxy acts as that ABS user: it sees only
  their libraries, and progress lands in their account.
* A token is freely chosen, at least 16 characters, and must be unique across
  all users — `openssl rand -hex 24` does the job. It is entered into that
  user's watch app settings later.
* The name (`manuel`, `anna`) names the user's cache directory and shows up in
  `/health` and the log: letters, digits, `_` and `-`.

Store the file as a Podman secret and delete the plain copy:

```sh
podman secret create abconnect-users users.toml
shred -u users.toml
```

The container gets it read-only at `/run/secrets/users.toml`.

### Changing users

Adding or removing a user, rotating a token or replacing an API key all work
the same way — edit the file, replace the secret, restart:

```sh
podman secret inspect --showsecret --format '{{.SecretData}}' abconnect-users > users.toml
$EDITOR users.toml
podman secret create --replace abconnect-users users.toml && shred -u users.toml
systemctl --user restart abconnect-proxy
```

A broken file keeps the container from starting; the journal lists every
problem at once: `journalctl --user -u abconnect-proxy -n 30`.

### Coming from the single-user setup

`ABS_URL` and the secrets `abs-api-key` and `abconnect-token` are gone. Read
the old values, put them into a users file — keeping the old token means the
watch needs no new settings — create `abconnect-users`, rerun
`./deploy/install.sh`, then drop the old secrets:

```sh
podman secret inspect --showsecret --format '{{.SecretData}}' abconnect-token
podman secret inspect --showsecret --format '{{.SecretData}}' abs-api-key
# ... users.toml, podman secret create, ./deploy/install.sh ...
podman secret rm abs-api-key abconnect-token
```

The cache now keeps one directory per user. Books from the old layout are
deleted on the first start and prepared again for their user; the segments come
out identical, so the watch keeps the copies it already has.

## 2. Install the units

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

`/health` reports one entry per user under `users`. `audiobookshelf: "ok"`
means: that user's address is correct and their API key is accepted.
`playlist_found: true` means their playlist was found under its name — if it
says `false`, the proxy mirrors nothing for them but also deletes nothing. If
any user's Audiobookshelf fails, `/health` answers 503. Anything else is a
misconfiguration that surfaces here instead of only on a watch's first sync.

## The playlist

What should end up on a watch is decided in that user's Audiobookshelf: create
a playlist named `Garmin` (or whatever `playlist` says for them) and add books
to it. The proxy prepares new entries on its own and releases removed ones
again; the watch mirrors that on the next sync.

If there is no playlist of that name, `/health` reports it as
`playlist_found: false` for that user and `/v1/playlist` answers with 409. The
watch then deletes nothing — a typo in the name does not wipe it.

Check by hand or trigger a single book — the watch no longer calls the
endpoints below `/v1/playlist`, but they are there for debugging. Every call
acts as the user whose token it carries:

```sh
TOKEN=<one user's token from users.toml>
curl -s -H "Authorization: Bearer $TOKEN" localhost:18543/v1/playlist | python3 -m json.tool
curl -s -H "Authorization: Bearer $TOKEN" localhost:18543/v1/books | python3 -m json.tool
curl -s -X POST -H "Authorization: Bearer $TOKEN" localhost:18543/v1/books/<ID>/prepare
curl -s -H "Authorization: Bearer $TOKEN" localhost:18543/v1/books/<ID>/status
curl -s -H "Authorization: Bearer $TOKEN" localhost:18543/v1/books/<ID>/segments | python3 -m json.tool
```

## Configuration

Users, their Audiobookshelf instances, keys and tokens live in the users file
(section 1). Everything else is global and comes from the environment:

| Variable | Required | Default | Meaning |
|---|---|---|---|
| `USERS_FILE` | — | `/run/secrets/users.toml` | the users file; the quadlet mounts the `abconnect-users` secret there |
| `ABS_PLAYLIST` | — | `Garmin` | playlist for every user without a `playlist` of their own |
| `PLAYLIST_POLL_SECONDS` | — | 600 | interval of the background reconciliation |
| `CACHE_DIR` | — | `/var/cache/abconnect` | segments and covers, one directory per user below `users/` |
| `WORK_DIR` | — | `/var/tmp/abconnect` | source file during the prepare job |
| `CACHE_MAX_BYTES` | — | 200 GiB | emergency brake for eviction, across all users |
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
the container, and `release` only unpins it. Force the re-cut (per user: it
re-cuts the copy of whoever's token is sent):

    curl -X POST -H "Authorization: Bearer $TOKEN" \
         "$PROXY_URL/v1/books/<book-id>/prepare?force=true"

Then reset the watch before syncing — the sync compares segments by index alone
and would otherwise keep the copies it already has.

## Rotating a token without locking out the watch

`tokens` is a list per user. Prepend the new token, replace the secret and
restart (see *Changing users*), enter it in that user's watch app settings,
then remove the old one from the list.
