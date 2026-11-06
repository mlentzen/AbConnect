"""One proxy, multiple users: everything behind a token belongs to one user.

Each user gets their own Audiobookshelf client, cache directory and playlist
watcher, so nobody reaches a book through the proxy that their own Audiobookshelf account
cannot see. The prepare slot is the one thing they share.
"""

from __future__ import annotations

import asyncio
import logging
from dataclasses import dataclass

from .abs_client import AbsClient
from .cache import USERS_DIR, Cache
from .config import Config, UserConfig
from .preparer import Preparer
from .watcher import PlaylistWatcher

log = logging.getLogger(__name__)


@dataclass
class UserRuntime:
    """Everything that belongs to one user while the process is running.

    Attributes:
        config: Their entry from the users file.
        abs: The HTTP client for that user's own Audiobookshelf.
        cache: Their segment directory.
        preparer: Turns one of their books into segments.
        watcher: Keeps their playlist and that cache in step.
    """

    config: UserConfig
    abs: AbsClient
    cache: Cache
    preparer: Preparer
    watcher: PlaylistWatcher


def build_runtimes(
    config: Config,
    slot: asyncio.Semaphore,
    abs_clients: dict[str, AbsClient] | None = None,
) -> dict[str, UserRuntime]:
    """Build one runtime per configured user.

    Args:
        config: The loaded process configuration.
        slot: Semaphore every preparer waits on, so only one book is
            downloaded and cut at a time, across users.
        abs_clients: User name mapped to an Audiobookshelf client that
            already exists. Tests pass fakes here, and nothing then dials
            the network. A user with no entry gets a client built from their
            abs_url and abs_api_key. A client passed in stays the caller's
            to close. Omit it in production.

    Returns:
        The runtimes keyed by user name.
    """
    abs_clients = abs_clients or {}
    caches = {
        user.name: Cache(root=config.cache_dir / USERS_DIR / user.name)
        for user in config.users
    }
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
            work_dir=config.work_dir / USERS_DIR / user.name,
            slot=slot,
        )
        watcher = PlaylistWatcher(
            abs_client=client,
            cache=cache,
            preparer=preparer,
            config=config,
            playlist=user.playlist,
        )
        runtimes[user.name] = UserRuntime(user, client, cache, preparer, watcher)

    # A user renamed or removed in the file leaves their directory behind. It
    # is only reported: a typo in the file must not wipe anyone's books.
    for directory in sorted((config.cache_dir / USERS_DIR).iterdir()):
        if directory.is_dir() and directory.name not in runtimes:
            log.warning(
                "Cache directory %s belongs to no configured user; delete it if obsolete",
                directory,
            )
    return runtimes
