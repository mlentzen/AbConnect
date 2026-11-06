"""One proxy, multiple users.

Each user has their own Audiobookshelf client and playlist watcher. Books are
prepared once into a shared cache and stay there while at least one playlist
still lists them. The library is family-shared, so a cached book is the same
book for every user.
"""

from __future__ import annotations

import asyncio
import logging
from dataclasses import dataclass

from .abs_client import AbsClient
from .cache import BOOKS_DIR, USERS_DIR, Cache
from .config import Config, UserConfig
from .preparer import Preparer
from .watcher import Holdings, PlaylistWatcher

log = logging.getLogger(__name__)


@dataclass
class UserRuntime:
    """Everything that belongs to one user while the process is running.

    Attributes:
        config: Their entry from the users file.
        abs: The HTTP client for that user's own Audiobookshelf.
        cache: The shared segment directory.
        preparer: Turns a book into segments, once for every user.
        watcher: Keeps their playlist and the shared cache in step.
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
        slot: Semaphore the shared preparer waits on, so only one book is
            downloaded and cut at a time.
        abs_clients: User name mapped to an Audiobookshelf client that
            already exists. Tests pass fakes here, and nothing then dials
            the network. A user with no entry gets a client built from their
            abs_url and abs_api_key. A client passed in stays the caller's
            to close. Omit it in production.

    Returns:
        The runtimes keyed by user name.
    """
    abs_clients = abs_clients or {}
    if not config.users:
        return {}

    clients = {
        user.name: abs_clients.get(user.name)
        or AbsClient(
            user.abs_url, user.abs_api_key, timeout=config.http_timeout_seconds
        )
        for user in config.users
    }
    cache = Cache(root=config.cache_dir / BOOKS_DIR)
    # One preparer, one scratch directory. The client stored here is only the
    # fallback for a job that did not say which account can read the book.
    preparer = Preparer(
        abs_client=clients[config.users[0].name],
        cache=cache,
        config=config,
        work_dir=config.work_dir,
        slot=slot,
    )
    holdings = Holdings()
    runtimes: dict[str, UserRuntime] = {}
    for user in config.users:
        holdings.add(user.name)
        client = clients[user.name]
        watcher = PlaylistWatcher(
            abs_client=client,
            cache=cache,
            preparer=preparer,
            config=config,
            playlist=user.playlist,
            user=user.name,
            holdings=holdings,
        )
        runtimes[user.name] = UserRuntime(user, client, cache, preparer, watcher)

    # Older builds kept one directory per user. Leaving it in place: a book
    # is prepared again into the shared cache, and a typo must not delete
    # anything on disk.
    obsolete = config.cache_dir / USERS_DIR
    if obsolete.is_dir():
        log.warning(
            "Cache directory %s is from per-user preparation and is no longer used; delete it if obsolete",
            obsolete,
        )
    return runtimes
