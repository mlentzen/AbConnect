"""Entry point. Aborts loudly when the environment is incomplete."""

from __future__ import annotations

import logging
import sys

import uvicorn

from . import media
from .api import create_app
from .config import ConfigError, load


def main() -> int:
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

    uvicorn.run(create_app(config), host="0.0.0.0", port=8080, log_level=config.log_level.lower())
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
