# <img src="app/resources/drawables/ab.svg" alt="" width="40" height="40"> AbConnect

[![build](https://github.com/mlentzen/AbConnect/actions/workflows/build.yml/badge.svg?branch=main)](https://github.com/mlentzen/AbConnect/actions/workflows/build.yml)
[![proxy image](https://github.com/mlentzen/AbConnect/actions/workflows/proxy-image.yml/badge.svg?branch=main)](https://github.com/mlentzen/AbConnect/actions/workflows/proxy-image.yml)
[![ghcr.io/mlentzen/abconnect-proxy](https://img.shields.io/badge/ghcr.io-mlentzen%2Fabconnect--proxy-0969da)](https://github.com/mlentzen/AbConnect/pkgs/container/abconnect-proxy)

Audiobookshelf as a Connect IQ audio provider for Garmin music watches.

Audiobooks from a self-hosted
[Audiobookshelf](https://www.audiobookshelf.org/) instance land on the watch,
play offline through the system media player, and listening progress goes back
to the server.

## Structure

**[`proxy/`](proxy/README.md)**. Container next to Audiobookshelf, run as a
Podman quadlet from the image GitHub publishes on the default branch.
Downloads an audiobook via the Audiobookshelf API and encodes every segment
to mp3 at a fixed bitrate per channel and 44.1 kHz, which is what the watch
will store. A stereo segment uses twice that bitrate.
An m4b becomes one file per chapter. An mp3 book stays one file per source
file. An m4b without chapters, or any other container, is not offered. The
source file is deleted again right away and the Audiobookshelf API key stays
server-side.

**[`app/`](app/README.md)**. Connect IQ app of type
`audio-content-provider-app` that downloads segments from the proxy, plays them and buffers
progress.

What ends up on the watch is decided by the Audiobookshelf playlist
**`Garmin`**: add a book and it appears; remove it and it disappears. Listening
progress goes back to the server on pause over Bluetooth and on sync over
Wi-Fi.

## Getting started

```sh
# Proxy: tests
uv sync --directory proxy --extra dev
uv run --directory proxy --extra dev pytest

# Proxy: install and run -> deploy/README.md
./deploy/install.sh

# Build the app yourself -> app/README.md
CIQ_HOME=/path/to/sdk ./app/build.sh
```

## Requirements

- Audiobookshelf ≥ 2.26 with an API key
- `abconnect-proxy` reachable over HTTPS
- Garmin watch with music storage and Wi-Fi. Initial target device is the fēnix 7X Pro.

## Contributing

The app is a personal project, and it has only been tested on one watch, a fēnix 7X Pro.

If you find a use for it, I welcome feedback and will extend the scope from there. [Issues](https://github.com/mlentzen/AbConnect/issues) are the place for that.
