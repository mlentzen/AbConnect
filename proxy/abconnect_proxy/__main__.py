"""Entry point. Aborts when the environment is incomplete."""

from __future__ import annotations

import logging
import sys

import uvicorn

from . import media
from .api import create_app
from .config import ConfigError, load


def main() -> int:
    """Load configuration, check that ffmpeg is installed, and serve until stopped.

    A configuration or ffmpeg problem is printed to stderr and the process
    exits before it binds the port.

    Returns:
        0 after a clean shutdown. 2 when configuration or ffmpeg is unusable.
    """
    try:
        config = load()
    except ConfigError as error:
        print(error, file=sys.stderr)
        return 2

    logging.basicConfig(
        level=config.log_level,
        format="%(asctime)s %(levelname)-7s %(name)s: %(message)s",
    )
    try:
        media.ensure_available()
    except media.MediaError as error:
        print(error, file=sys.stderr)
        return 2

    config.cache_dir.mkdir(parents=True, exist_ok=True)
    config.work_dir.mkdir(parents=True, exist_ok=True)

    # Behind the reverse proxy, uvicorn takes the client address from
    # X-Forwarded-For only when the peer is listed in FORWARDED_ALLOW_IPS
    # (default 127.0.0.1). The failed-auth lockout keys on that address.
    uvicorn.run(
        create_app(config),
        host="0.0.0.0",
        port=8080,
        log_level=config.log_level.lower(),
        server_header=False,
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
