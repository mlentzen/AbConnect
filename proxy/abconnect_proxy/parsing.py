from __future__ import annotations

from dataclasses import dataclass, field

from .models import Chapter, SourceFile


class ItemUnusable(Exception):
    """The item cannot be prepared.

    The message is plain text the watch can show.
    """


@dataclass
class ParsedItem:
    """One library item reduced to what preparation needs.

    Chapters may be empty. For an m4b the segmenter withholds the book;
    for mp3 files the chapters are ignored.

    Attributes:
        title: Book title.
        author: Book author. Empty when Audiobookshelf names none.
        duration: Length in seconds, from the item or from its files.
        files: Audio files in playback order. Each file's ino is how that
            file is downloaded.
        chapters: Markers Audiobookshelf sent.
    """

    title: str
    author: str
    duration: float
    files: list[SourceFile] = field(default_factory=list)
    chapters: list[Chapter] = field(default_factory=list)

    @property
    def total_bytes(self) -> int:
        return sum(f.size for f in self.files)


def _number(value, default: float = 0.0) -> float:
    try:
        return float(value)
    except (TypeError, ValueError):
        return default


def _metadata(media: dict) -> dict:
    return media.get("metadata") or {}


def _author(metadata: dict) -> str:
    if metadata.get("authorName"):
        return str(metadata["authorName"])
    authors = metadata.get("authors") or []
    names = [a.get("name") for a in authors if isinstance(a, dict) and a.get("name")]
    return ", ".join(names)


def parse_item(payload: dict) -> ParsedItem:
    """Parse the expanded response of GET /api/items/{id}.

    The minified form omits files and chapters, so this expects expanded=1.
    A book with no addressable audio file is refused instead of coming back
    half-parsed.

    Args:
        payload: JSON object for one library item.

    Returns:
        The item reduced to files, chapters and duration.

    Raises:
        ItemUnusable: The response has no item, or the item has no audio
            file that can be downloaded.
    """
    if not isinstance(payload, dict) or not payload.get("id"):
        raise ItemUnusable("Response contains no item")

    media = payload.get("media") or {}
    metadata = _metadata(media)
    title = str(metadata.get("title") or payload.get("relPath") or payload["id"])

    audio_files = media.get("audioFiles") or []
    if not audio_files:
        raise ItemUnusable(f"'{title}' has no audio files (eBook only?)")

    files: list[SourceFile] = []
    for entry in sorted(audio_files, key=lambda f: _number(f.get("index"), 0)):
        if entry.get("invalid") or entry.get("exclude"):
            continue
        file_metadata = entry.get("metadata") or {}
        duration = _number(entry.get("duration"))
        if duration <= 0:
            raise ItemUnusable(
                f"'{title}': file {file_metadata.get('filename', '?')} without duration"
            )
        files.append(
            SourceFile(
                ino=str(entry.get("ino") or ""),
                filename=str(file_metadata.get("filename") or f"{entry.get('index')}"),
                duration=duration,
                size=int(_number(file_metadata.get("size"))),
            )
        )

    if not files:
        raise ItemUnusable(f"'{title}': all audio files are marked as invalid")
    if any(not f.ino for f in files):
        raise ItemUnusable(
            f"'{title}': audio file without ino, download not addressable"
        )

    chapters = []
    for entry in media.get("chapters") or []:
        chapters.append(
            Chapter(
                start=_number(entry.get("start")),
                end=_number(entry.get("end")),
                title=str(entry.get("title") or f"Chapter {len(chapters) + 1}"),
            )
        )

    duration = _number(media.get("duration")) or sum(f.duration for f in files)

    return ParsedItem(
        title=title,
        author=_author(metadata),
        duration=duration,
        files=files,
        chapters=chapters,
    )


@dataclass
class Playlist:
    """One Audiobookshelf playlist.

    Attributes:
        name: Playlist name. Reconciliation matches on this.
        books: Title, author and duration for each book, in playlist order,
            taken from the embedded library item so the watch does not need
            a second request per book.
    """

    name: str
    books: list[dict] = field(default_factory=list)


def parse_playlists(payload) -> list[Playlist]:
    """Parse the response of GET /api/playlists.

    An entry that is not a library item is skipped: a podcast episode, or a
    row without an item id. A segment always belongs to an item.

    Args:
        payload: JSON from the playlists endpoint. Either the whole object
            or the list under its "playlists" key.

    Returns:
        The playlists, each with its books.
    """
    entries = payload.get("playlists") if isinstance(payload, dict) else payload
    result: list[Playlist] = []
    for entry in entries or []:
        if not isinstance(entry, dict) or not entry.get("id"):
            continue
        playlist = Playlist(name=str(entry.get("name") or ""))
        for item in entry.get("items") or []:
            if not isinstance(item, dict):
                continue
            # Podcast episodes carry an episodeId; the watch cannot address
            # those because a segment always belongs to an item.
            if item.get("episodeId"):
                continue
            book_id = item.get("libraryItemId")
            if not book_id:
                continue
            book_id = str(book_id)
            library_item = item.get("libraryItem")
            metadata = _metadata((library_item or {}).get("media") or {})
            playlist.books.append(
                {
                    "id": book_id,
                    "title": str(metadata.get("title") or book_id),
                    "author": _author(metadata),
                    "duration": round(
                        _number(
                            ((library_item or {}).get("media") or {}).get("duration")
                        ),
                        1,
                    ),
                }
            )
        result.append(playlist)
    return result


def find_playlist(playlists: list[Playlist], name: str) -> Playlist | None:
    """Find a playlist by name.

    Audiobookshelf cannot search playlists by name, so the caller passes the
    full list. Matching ignores case and surrounding whitespace.

    Args:
        playlists: Playlists already parsed.
        name: Name to look for.

    Returns:
        The matching playlist, or None.
    """
    wanted = name.casefold().strip()
    for playlist in playlists:
        if playlist.name.casefold().strip() == wanted:
            return playlist
    return None
