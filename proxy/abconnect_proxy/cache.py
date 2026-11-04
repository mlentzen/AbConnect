from __future__ import annotations

import json
import logging
import re
import shutil
import time
from dataclasses import dataclass
from pathlib import Path

log = logging.getLogger(__name__)

SAFE_ID = re.compile(r"^[A-Za-z0-9_.-]{1,128}$")
MANIFEST = "manifest.json"
STATE = "state.json"
SEGMENTS = "seg"
USERS_DIR = "users"


class UnsafeBookId(ValueError):
    pass


def check_id(book_id: str) -> str:
    """Accept a book id only when it is safe as a single directory name.

    Ids become path segments under the cache, so anything with a slash, a
    parent reference or an empty value is refused before it can leave that
    directory.

    Args:
        book_id: Value taken from a request or a playlist.

    Returns:
        The same id, when it is safe.

    Raises:
        UnsafeBookId: The id would not stay inside its cache directory.
    """
    if not SAFE_ID.match(book_id or ""):
        raise UnsafeBookId(f"Invalid book ID: {book_id!r}")
    return book_id


@dataclass
class Cache:
    """One user's segment directories.

    Attributes:
        root: Directory this user's books live under.
    """

    root: Path

    def __post_init__(self) -> None:
        self.root.mkdir(parents=True, exist_ok=True)

    # --- Paths ---------------------------------------------------------------

    def book_dir(self, book_id: str) -> Path:
        return self.root / check_id(book_id)

    def manifest_path(self, book_id: str) -> Path:
        return self.book_dir(book_id) / MANIFEST

    def segment_path(self, book_id: str, filename: str) -> Path:
        if "/" in filename or ".." in filename:
            raise UnsafeBookId(f"Invalid segment name: {filename!r}")
        return self.book_dir(book_id) / SEGMENTS / filename

    # --- Manifest ------------------------------------------------------------

    def is_ready(self, book_id: str) -> bool:
        """Report whether the book's manifest is on disk.

        A manifest survives a process restart, so a ready book stays ready.

        Args:
            book_id: Audiobookshelf library-item id.

        Returns:
            True when the manifest file exists.
        """
        return self.manifest_path(book_id).exists()

    def load_manifest(self, book_id: str) -> dict | None:
        path = self.manifest_path(book_id)
        if not path.exists():
            return None
        try:
            return json.loads(path.read_text(encoding="utf-8"))
        except (json.JSONDecodeError, OSError):
            log.warning(
                "Manifest of %s is unreadable, book counts as not prepared", book_id
            )
            return None

    def store_manifest(self, book_id: str, manifest: dict) -> None:
        path = self.manifest_path(book_id)
        path.parent.mkdir(parents=True, exist_ok=True)
        # Write alongside first, then rename: an aborted write must not leave a
        # half manifest behind that passes as "ready".
        temporary = path.with_suffix(".tmp")
        temporary.write_text(
            json.dumps(manifest, ensure_ascii=False, indent=1), encoding="utf-8"
        )
        temporary.replace(path)

    # --- State -------------------------------------------------------------

    def _state(self, book_id: str) -> dict:
        path = self.book_dir(book_id) / STATE
        if not path.exists():
            return {"pinned": False, "released_at": None, "last_access": 0.0}
        try:
            return json.loads(path.read_text(encoding="utf-8"))
        except (json.JSONDecodeError, OSError):
            return {"pinned": False, "released_at": None, "last_access": 0.0}

    def _write_state(self, book_id: str, state: dict) -> None:
        directory = self.book_dir(book_id)
        directory.mkdir(parents=True, exist_ok=True)
        (directory / STATE).write_text(json.dumps(state), encoding="utf-8")

    def pin(self, book_id: str, now: float | None = None) -> None:
        """Mark the book as selected so it is not evicted.

        Args:
            book_id: Audiobookshelf library-item id.
            now: Timestamp to store as the last access. Omit it to use the
                current time.
        """
        state = self._state(book_id)
        state.update(
            pinned=True,
            released_at=None,
            last_access=time.time() if now is None else now,
        )
        self._write_state(book_id, state)

    def release(self, book_id: str, now: float | None = None) -> None:
        """Mark the book as no longer needed.

        The files stay until the release TTL expires, so selecting it again
        does not require another download.

        Args:
            book_id: Audiobookshelf library-item id.
            now: Timestamp stored as the release time. Omit it to use the
                current time.
        """
        state = self._state(book_id)
        state.update(pinned=False, released_at=time.time() if now is None else now)
        self._write_state(book_id, state)

    def touch(self, book_id: str, now: float | None = None) -> None:
        """Record that the book was just used.

        The budget evicts the least recently used unpinned books first.

        Args:
            book_id: Audiobookshelf library-item id.
            now: Timestamp to store. Omit it to use the current time.
        """
        state = self._state(book_id)
        state["last_access"] = time.time() if now is None else now
        self._write_state(book_id, state)

    def pinned(self, book_id: str) -> bool:
        return bool(self._state(book_id).get("pinned"))

    # --- Space ---------------------------------------------------------------

    def book_bytes(self, book_id: str) -> int:
        directory = self.book_dir(book_id)
        if not directory.exists():
            return 0
        return sum(f.stat().st_size for f in directory.rglob("*") if f.is_file())

    def total_bytes(self) -> int:
        return sum(f.stat().st_size for f in self.root.rglob("*") if f.is_file())

    def books(self) -> list[str]:
        return sorted(d.name for d in self.root.iterdir() if d.is_dir())

    def discard(self, book_id: str) -> None:
        """Delete the book's directory, manifest and segments included.

        Args:
            book_id: Audiobookshelf library-item id.
        """
        shutil.rmtree(self.book_dir(book_id), ignore_errors=True)

    def sweep(self, ttl_days: int, now: float | None = None) -> list[str]:
        """Delete released books whose TTL has expired.

        Args:
            ttl_days: How long a released book may stay. Zero or less deletes
                nothing.
            now: Clock the ages are compared against. Omit it to use the
                current time.

        Returns:
            The book ids that were deleted.
        """
        if ttl_days <= 0:
            return []
        now = time.time() if now is None else now
        deadline = ttl_days * 86400
        evicted = []
        for book_id in self.books():
            state = self._state(book_id)
            released = state.get("released_at")
            if state.get("pinned") or released is None:
                continue
            if now - released > deadline:
                self.discard(book_id)
                evicted.append(book_id)
        return evicted

    def eviction_candidates(self) -> list[tuple[float, str]]:
        """List the books the budget is allowed to evict.

        Returns:
            Pairs of last-access time and book id, for books that are not
            pinned.
        """
        candidates = []
        for book_id in self.books():
            state = self._state(book_id)
            if not state.get("pinned"):
                candidates.append((state.get("last_access") or 0.0, book_id))
        return candidates


@dataclass
class Budget:
    """One disk budget across every user's cache.

    A book prepared for one user can push out another user's released books,
    least recently used first. Pinned books, on someone's watch right now,
    are left in place.

    Attributes:
        max_bytes: CACHE_MAX_BYTES. This is the disk, not a per-person quota.
        caches: User name mapped to that user's cache.
    """

    max_bytes: int
    caches: dict[str, Cache]

    def total_bytes(self) -> int:
        return sum(cache.total_bytes() for cache in self.caches.values())

    def has_room_for(self, needed_bytes: int) -> bool:
        return self.total_bytes() + needed_bytes <= self.max_bytes

    def enforce(self) -> list[tuple[str, str]]:
        """Evict unpinned books until the cache is within its budget.

        Returns:
            Pairs of user name and book id for everything evicted. Empty when
            the cache was already within budget.
        """
        total = self.total_bytes()
        if total <= self.max_bytes:
            return []

        candidates = sorted(
            (access, owner, book_id)
            for owner, cache in self.caches.items()
            for access, book_id in cache.eviction_candidates()
        )

        evicted = []
        for _, owner, book_id in candidates:
            if total <= self.max_bytes:
                break
            cache = self.caches[owner]
            total -= cache.book_bytes(book_id)
            cache.discard(book_id)
            evicted.append((owner, book_id))
            log.info("Cache over budget: %s of %s evicted", book_id, owner)
        if total > self.max_bytes:
            log.warning("Cache still over budget. All remaining books are pinned")
        return evicted
