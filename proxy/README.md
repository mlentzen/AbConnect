# abconnect-proxy

[![proxy image](https://github.com/mlentzen/AbConnect/actions/workflows/proxy-image.yml/badge.svg?branch=main)](https://github.com/mlentzen/AbConnect/actions/workflows/proxy-image.yml)
[![ghcr.io/mlentzen/abconnect-proxy](https://img.shields.io/badge/ghcr.io-mlentzen%2Fabconnect--proxy-0969da)](https://github.com/mlentzen/AbConnect/pkgs/container/abconnect-proxy)

Companion server between Audiobookshelf and the Connect IQ app.

## Development

```sh
uv sync --extra dev
uv run --extra dev pytest
```
Operation and configuration: [../deploy/README.md](../deploy/README.md).
