"""ABS JSON -> our own models.

Deliberately lenient: Audiobookshelf has moved field names between versions,
and a missing secondary field must not make a book invisible. What is really
missing (files, duration) surfaces as ItemUnusable with plain text.
"""

from __future__ import annotations

from dataclasses import dataclass, field

from .models import Chapter, SourceFile, UnsupportedCodec, encoding_for


class ItemUnusable(Exception):
    pass


@dataclass
class ParsedItem:
    id: str
    title: str
    author: str
    duration: float
    files: list[SourceFile] = field(default_factory=list)
    chapters: list[Chapter] = field(default_factory=list)
    has_cover: bool = False

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
    """Expects the response of GET /api/items/{id} (not minified)."""
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
        codec = str(entry.get("codec") or "")
        try:
            encoding_for(codec)
        except UnsupportedCodec as error:
            raise ItemUnusable(f"'{title}': {error}") from None
        duration = _number(entry.get("duration"))
        if duration <= 0:
            raise ItemUnusable(f"'{title}': file {file_metadata.get('filename', '?')} without duration")
        files.append(
            SourceFile(
                ino=str(entry.get("ino") or ""),
                filename=str(file_metadata.get("filename") or f"{entry.get('index')}"),
                duration=duration,
                size=int(_number(file_metadata.get("size"))),
                codec=codec,
            )
        )

    if not files:
        raise ItemUnusable(f"'{title}': all audio files are marked as invalid")
    if any(not f.ino for f in files):
        raise ItemUnusable(f"'{title}': audio file without ino, download not addressable")

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
        id=str(payload["id"]),
        title=title,
        author=_author(metadata),
        duration=duration,
        files=files,
        chapters=chapters,
        has_cover=bool(media.get("coverPath") or payload.get("coverPath")),
    )


def parse_listing(payload: dict) -> tuple[list[dict], int]:
    """GET /api/libraries/{id}/items -> slim entries plus total count."""
    results = payload.get("results") if isinstance(payload, dict) else None
    if results is None:
        results = payload if isinstance(payload, list) else []

    books = []
    for entry in results:
        if not isinstance(entry, dict) or not entry.get("id"):
            continue
        media = entry.get("media") or {}
        metadata = _metadata(media)
        books.append(
            {
                "id": str(entry["id"]),
                "title": str(metadata.get("title") or entry.get("relPath") or entry["id"]),
                "author": _author(metadata),
                "duration": round(_number(media.get("duration")), 1),
            }
        )
    total = int(_number(payload.get("total"), len(books))) if isinstance(payload, dict) else len(books)
    return books, total


def parse_book_libraries(payload: dict) -> list[str]:
    libraries = payload.get("libraries") if isinstance(payload, dict) else payload
    return [
        str(library["id"])
        for library in (libraries or [])
        if isinstance(library, dict) and library.get("id") and library.get("mediaType", "book") == "book"
    ]


@dataclass
class Playlist:
    id: str
    name: str
    book_ids: list[str] = field(default_factory=list)
    #! Take title and author along right away: the embedded libraryItem objects
    #! save the watch a second call per book.
    books: list[dict] = field(default_factory=list)


def parse_playlists(payload) -> list[Playlist]:
    """GET /api/playlists -> playlists with their book IDs."""
    entries = payload.get("playlists") if isinstance(payload, dict) else payload
    result: list[Playlist] = []
    for entry in entries or []:
        if not isinstance(entry, dict) or not entry.get("id"):
            continue
        playlist = Playlist(id=str(entry["id"]), name=str(entry.get("name") or ""))
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
            playlist.book_ids.append(book_id)
            library_item = item.get("libraryItem")
            metadata = _metadata((library_item or {}).get("media") or {})
            playlist.books.append(
                {
                    "id": book_id,
                    "title": str(metadata.get("title") or book_id),
                    "author": _author(metadata),
                    "duration": round(_number(((library_item or {}).get("media") or {}).get("duration")), 1),
                }
            )
        result.append(playlist)
    return result


def find_playlist(playlists: list[Playlist], name: str) -> Playlist | None:
    """Resolution by name — ABS has no search for it."""
    wanted = name.casefold().strip()
    for playlist in playlists:
        if playlist.name.casefold().strip() == wanted:
            return playlist
    return None
