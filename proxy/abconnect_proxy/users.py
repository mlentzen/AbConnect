"""One proxy, several people: everything behind a token belongs to one user.

Each user gets their own ABS client, cache directory and playlist watcher, so
nobody reaches a book through the proxy that their own Audiobookshelf account
cannot see. Only two things are shared: the disk budget, and the prepare slot —
one job at a time across all users keeps disk usage predictable.
"""

from __future__ import annotations

import asyncio
import logging
from dataclasses import dataclass

from .abs_client import AbsClient
from .cache import USERS_DIR, Budget, Cache
from .config import Config, UserConfig
from .preparer import Preparer
from .reconciler import PlaylistReconciler

log = logging.getLogger(__name__)


@dataclass
class UserRuntime:
    config: UserConfig
    abs: AbsClient
    cache: Cache
    preparer: Preparer
    reconciler: PlaylistReconciler


def build_runtimes(
    config: Config,
    slot: asyncio.Semaphore,
    abs_clients: dict[str, AbsClient] | None = None,
) -> tuple[dict[str, UserRuntime], Budget]:
    """`abs_clients` injects ABS clients by user name (tests); the rest are created here."""
    abs_clients = abs_clients or {}
    caches = {user.name: Cache(root=config.cache_dir / USERS_DIR / user.name) for user in config.users}
    budget = Budget(max_bytes=config.cache_max_bytes, caches=caches)

    runtimes: dict[str, UserRuntime] = {}
    for user in config.users:
        cache = caches[user.name]
        client = abs_clients.get(user.name) or AbsClient(
            user.abs_url, user.abs_api_key, timeout=config.http_timeout_seconds
        )
        preparer = Preparer(
            abs_client=client,
            cache=cache,
            config=config,
            budget=budget,
            work_dir=config.work_dir / USERS_DIR / user.name,
            slot=slot,
        )
        reconciler = PlaylistReconciler(
            abs_client=client, cache=cache, preparer=preparer, config=config, playlist=user.playlist
        )
        runtimes[user.name] = UserRuntime(user, client, cache, preparer, reconciler)

    # A user renamed or removed in the file leaves their directory behind. It
    # is only reported: a typo in the file must not wipe anyone's books.
    for directory in sorted((config.cache_dir / USERS_DIR).iterdir()):
        if directory.is_dir() and directory.name not in runtimes:
            log.warning("Cache directory %s belongs to no configured user; delete it if obsolete", directory)
    return runtimes, budget
