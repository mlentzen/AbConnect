# abconnect-proxy

[![proxy image](https://github.com/mlentzen/AbConnect/actions/workflows/proxy-image.yml/badge.svg?branch=main)](https://github.com/mlentzen/AbConnect/actions/workflows/proxy-image.yml)
[![ghcr.io/mlentzen/abconnect-proxy](https://img.shields.io/badge/ghcr.io-mlentzen%2Fabconnect--proxy-0969da)](https://github.com/mlentzen/AbConnect/pkgs/container/abconnect-proxy)

Companion server between Audiobookshelf and the Connect IQ app.

It downloads an audiobook via the Audiobookshelf API. A book that is already
a set of mp3 files is kept as those files. An m4b is cut into one mp3 per
chapter, and the source file is deleted right away. An m4b without chapters,
or any other container, is not offered. The watch only gets lean JSON
responses and finished mp3 files; the Audiobookshelf API key stays here.

## Development

```sh
uv sync --extra dev
uv run --extra dev pytest
```

The tests need `ffmpeg` and `ffprobe` on the `PATH`. They create real m4b
files with chapter markers, cut them and verify the result with `ffprobe`.
Without ffmpeg these tests are skipped, the rest runs.

Operation and configuration: [../deploy/README.md](../deploy/README.md).
