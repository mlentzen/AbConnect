# Running abconnect-proxy

[![ghcr.io/mlentzen/abconnect-proxy](https://img.shields.io/badge/ghcr.io-mlentzen%2Fabconnect--proxy-0969da)](https://github.com/mlentzen/AbConnect/pkgs/container/abconnect-proxy)

Setup is described for Podman Quadlet. The image also runs under Docker Compose, but no compose file is provided.

## Users

One proxy serves any number of people. Each entry is one Audiobookshelf account, its API key, the playlist the watch mirrors, and the token the watch sends. The token is the only thing the watch knows.

```toml
[users.alex]
tokens = ["<token for alex's watch>"]
abs_url = "https://audiobookshelf.example.com"
abs_api_key = "<API key of alex's ABS account>"
playlist = "Garmin"            # optional, defaults to Garmin

[users.anna]
tokens = ["<token for anna's watch>"]
abs_url = "https://audiobookshelf.example.com"
abs_api_key = "<API key of anna's ABS account>"
```

* The API key is created in Audiobookshelf under *Settings → Users → API Keys*. The proxy acts as that user.
* A token is at least 16 characters and unique across all users. `openssl rand -hex 24`. It goes into that user's watch app settings.
* The name (`alex`) is the log label: letters, digits, `_` and `-`. Books are prepared once for everyone, not into a directory per person.
* `bitrate_kbps` re-encodes each chapter to that file rate when that person's watch downloads it, then deletes the temporary file. The channel count stays as stored. `mono = true` also mixes it down to one channel; without `bitrate_kbps` that mix uses `TRANSCODE_BITRATE_KBPS`. A chapter that already matches is sent as stored. The shared cache stays as prepared. Chapters already stored on the watch stay until that watch asks for them again.

```sh
podman secret create abconnect-users users.toml
shred -u users.toml
```

The container reads it at `/run/secrets/users.toml`. A broken file refuses to start; `journalctl --user -u abconnect-proxy -n 30` lists every problem.

Replace the secret and restart to change it:

```sh
podman secret inspect --showsecret --format '{{.SecretData}}' abconnect-users > users.toml
$EDITOR users.toml
podman secret create --replace abconnect-users users.toml && shred -u users.toml
systemctl --user restart abconnect-proxy
```
## Install

```sh
./deploy/install.sh
```

The script installs the quadlet and starts `ghcr.io/mlentzen/abconnect-proxy:latest`, published when `proxy/` changes on `main`. A failed publish leaves the running image in place.

The proxy listens on `127.0.0.1:18543`.

## Updates

Optional. The container is labeled `AutoUpdate=registry`.

```sh
systemctl --user start podman-auto-update.service          # once
systemctl --user enable --now podman-auto-update.timer     # daily
```

## Check

```sh
curl -s localhost:18543/health
TOKEN=<one user's token>
curl -s -H "Authorization: Bearer $TOKEN" localhost:18543/v1/status | python3 -m json.tool
```

`/health` answers `{"status": "ok"}` and names no user. `/v1/status` is that token's user: `audiobookshelf: "ok"` means the address and API key work. `playlist_found: false` means that playlist is missing; the proxy leaves the watch alone, and `/v1/playlist` answers 409.

Books on the watch are that user's Audiobookshelf playlist (`Garmin`, or the entry's `playlist`).

## Configuration

Environment on the quadlet. Unset variables keep these defaults.

| Variable | Default | Meaning |
|---|---|---|
| `ABS_PLAYLIST` | `Garmin` | playlist when a user sets none |
| `TRANSCODE_BITRATE_KBPS` | 64 | bitrate per channel; a stereo segment uses twice this |
| `LOG_LEVEL` | `INFO` | |
| `FORWARDED_ALLOW_IPS` | `127.0.0.1` | peers whose `X-Forwarded-For` is trusted |
