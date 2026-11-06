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
BOOKS_DIR = "books"
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
            return {"pinned": False, "last_access": 0.0}
        try:
            return json.loads(path.read_text(encoding="utf-8"))
        except (json.JSONDecodeError, OSError):
            return {"pinned": False, "last_access": 0.0}

    def _write_state(self, book_id: str, state: dict) -> None:
        directory = self.book_dir(book_id)
        directory.mkdir(parents=True, exist_ok=True)
        (directory / STATE).write_text(json.dumps(state), encoding="utf-8")

    def pin(self, book_id: str, now: float | None = None) -> None:
        """Mark the book as selected for this user's watch.

        Args:
            book_id: Audiobookshelf library-item id.
            now: Timestamp to store as the last access. Omit it to use the
                current time.
        """
        state = self._state(book_id)
        state.update(
            pinned=True,
            last_access=time.time() if now is None else now,
        )
        self._write_state(book_id, state)

    def touch(self, book_id: str, now: float | None = None) -> None:
        """Record that the book was just used.

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
