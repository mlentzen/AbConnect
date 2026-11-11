from __future__ import annotations

import math
from dataclasses import dataclass
from itertools import pairwise
from pathlib import Path

from .config import DEFAULTS
from .models import Chapter, Segment, SegmentPlan, SourceFile

TOLERANCE = 0.5


class NotForWatch(Exception):
    """The book must not be offered to the watch.

    The message is the reason, in plain text, for the log.
    """


@dataclass
class _Piece:
    """One slice of a chapter that lies inside a single source file.

    Attributes:
        file_index: Which source file this slice comes from.
        source_start: Start inside that file, in seconds.
        source_end: End inside that file, in seconds.
        book_start: Start in absolute book time, in seconds.
        title: Chapter title this slice inherits.
        chapter_index: Which chapter this slice came from.
    """

    file_index: int
    source_start: float
    source_end: float
    book_start: float
    title: str
    chapter_index: int

    @property
    def duration(self) -> float:
        return self.source_end - self.source_start


def validate_chapters(chapters: list[Chapter], total_duration: float) -> str:
    """Decide whether chapter markers can be cut from.

    Markers are unusable when they are missing, unsorted, overlapping, or
    do not lie inside the book. The caller then withholds the book.

    Args:
        chapters: Markers in the order Audiobookshelf sent them.
        total_duration: Length of the book, in seconds.

    Returns:
        An empty string when the chapters can be used. Otherwise a short
        reason they cannot.
    """
    if not chapters:
        return "no chapter markers present"

    ordered = sorted(chapters, key=lambda c: c.start)
    if ordered != list(chapters):
        return "chapters are not sorted chronologically"

    for chapter in ordered:
        if chapter.duration <= 0:
            return f"chapter '{chapter.title}' has no duration"
    for previous, current in pairwise(ordered):
        if current.start < previous.end - TOLERANCE:
            return f"chapters overlap at '{current.title}'"

    if ordered[0].start < -TOLERANCE:
        return "first chapter begins before the start of the book"
    if ordered[-1].end > total_duration + TOLERANCE:
        return "chapters extend beyond the book duration"

    return ""


def _snap(chapters: list[Chapter], total_duration: float) -> list[Chapter]:
    """Stretch chapters so no audio falls in a gap.

    The first chapter starts at 0, the last ends at the book duration, and
    a gap between two chapters is given to the earlier one.

    Args:
        chapters: Markers already accepted by validate_chapters.
        total_duration: Length of the book, in seconds.

    Returns:
        The same chapters with their edges closed.
    """
    snapped = list(chapters)
    first, last = snapped[0], snapped[-1]
    snapped[0] = Chapter(0.0, first.end, first.title)
    snapped[-1] = Chapter(snapped[-1].start, total_duration, last.title)
    # Add gaps between chapters to the preceding one.
    for i in range(len(snapped) - 1):
        if snapped[i + 1].start > snapped[i].end + TOLERANCE:
            snapped[i] = Chapter(
                snapped[i].start, snapped[i + 1].start, snapped[i].title
            )
    return snapped


def _split_at_file_boundaries(
    chapters: list[Chapter], files: list[SourceFile]
) -> list[_Piece]:
    bounds: list[tuple[float, float]] = []
    cursor = 0.0
    for source in files:
        bounds.append((cursor, cursor + source.duration))
        cursor += source.duration

    pieces: list[_Piece] = []
    for chapter_index, chapter in enumerate(chapters):
        for file_index, (file_start, file_end) in enumerate(bounds):
            start = max(chapter.start, file_start)
            end = min(chapter.end, file_end)
            if end - start <= TOLERANCE:
                continue
            pieces.append(
                _Piece(
                    file_index=file_index,
                    source_start=start - file_start,
                    source_end=end - file_start,
                    book_start=start,
                    title=chapter.title,
                    chapter_index=chapter_index,
                )
            )
    return pieces


def _number_titles(pieces: list[_Piece]) -> None:
    """Number titles when one chapter produced several segments.

    "Chapter 3" becomes "Chapter 3 (1/2)" when the chapter crosses a file
    boundary. A chapter that stayed in one piece keeps its title.

    Args:
        pieces: Slices whose titles are updated in place.
    """
    counts: dict[int, int] = {}
    for piece in pieces:
        counts[piece.chapter_index] = counts.get(piece.chapter_index, 0) + 1
    seen: dict[int, int] = {}
    for piece in pieces:
        total = counts[piece.chapter_index]
        if total == 1:
            continue
        seen[piece.chapter_index] = seen.get(piece.chapter_index, 0) + 1
        piece.title = f"{piece.title} ({seen[piece.chapter_index]}/{total})"


def _suffixes(files: list[SourceFile]) -> set[str]:
    return {Path(source.filename).suffix.lower() for source in files}


def _duration_limit(max_duration: float | None) -> float:
    """Resolve the longest piece, in seconds.

    Args:
        max_duration: Caller override. ``None`` reads the configuration.

    Returns:
        The limit.

    Raises:
        ValueError: The limit is not positive.
    """
    limit = float(
        DEFAULTS["MAX_FILE_DURATION_SECONDS"] if max_duration is None else max_duration
    )
    if limit <= 0:
        raise ValueError("max duration must be positive")
    return limit


def _spans(duration: float, limit: float) -> list[tuple[float, float]]:
    """Pieces of one file, each at most ``limit`` seconds.

    A tail shorter than the cut tolerance stays on the previous piece, so a
    file is not given a sliver and no audio is dropped.

    Args:
        duration: Length of the file, in seconds.
        limit: Longest piece, in seconds. Must be positive.

    Returns:
        ``(start, end)`` pairs inside the file, in order.
    """
    if duration <= limit:
        return [(0.0, duration)]

    spans: list[tuple[float, float]] = []
    start = 0.0
    while start < duration:
        end = min(start + limit, duration)
        if 0 < duration - end <= TOLERANCE:
            end = duration
        spans.append((start, end))
        start = end
    return spans


def _plan_mp3(files: list[SourceFile], max_duration: float) -> SegmentPlan:
    """One segment per file, cut again when a file is longer than ``max_duration``."""
    segments: list[Segment] = []
    cursor = 0.0
    for file_index, source in enumerate(files):
        stem = Path(source.filename).stem or f"Track {file_index + 1}"
        spans = _spans(source.duration, max_duration)
        for part, (start, end) in enumerate(spans):
            title = stem if len(spans) == 1 else f"{stem}-{part:02d}.mp3"
            segments.append(
                Segment(
                    index=len(segments),
                    title=title,
                    source_ino=source.ino,
                    source_start=round(start, 3),
                    source_end=round(end, 3),
                    book_start=round(cursor + start, 3),
                )
            )
        cursor += source.duration
    return SegmentPlan(segments=segments, chapter_source="files", total_duration=cursor)


def _equal_parts(piece: _Piece, limit: float) -> list[_Piece]:
    """Split one in-file slice into equal parts of at most ``limit`` seconds.

    A slice that already fits is returned unchanged. The last part ends
    where the slice ends, so the parts cover it exactly.

    Args:
        piece: One chapter slice inside a single source file.
        limit: Longest part, in seconds.

    Returns:
        The original slice, or the equal parts in order.
    """
    duration = piece.duration
    if duration <= limit:
        return [piece]

    count = math.ceil(duration / limit)
    part = duration / count
    parts: list[_Piece] = []
    for index in range(count):
        start = index * part
        end = duration if index == count - 1 else (index + 1) * part
        parts.append(
            _Piece(
                file_index=piece.file_index,
                source_start=piece.source_start + start,
                source_end=piece.source_start + end,
                book_start=piece.book_start + start,
                title=piece.title,
                chapter_index=piece.chapter_index,
            )
        )
    return parts


def _plan_m4b(
    files: list[SourceFile], chapters: list[Chapter], max_duration: float
) -> SegmentPlan:
    """One segment per chapter.

    A chapter is cut where it crosses two files, and a piece longer than
    ``max_duration`` is then split into equal parts.
    """
    total_duration = sum(source.duration for source in files)
    reason = validate_chapters(chapters, total_duration)
    if reason:
        raise NotForWatch(reason)

    pieces = [
        part
        for piece in _split_at_file_boundaries(_snap(chapters, total_duration), files)
        for part in _equal_parts(piece, max_duration)
    ]
    if not pieces:
        raise NotForWatch("chapters do not overlap the audio")
    _number_titles(pieces)

    segments = [
        Segment(
            index=index,
            title=piece.title,
            source_ino=files[piece.file_index].ino,
            source_start=round(piece.source_start, 3),
            source_end=round(piece.source_end, 3),
            book_start=round(piece.book_start, 3),
        )
        for index, piece in enumerate(pieces)
    ]
    return SegmentPlan(
        segments=segments, chapter_source="chapters", total_duration=total_duration
    )


def plan_segments(
    files: list[SourceFile],
    chapters: list[Chapter],
    max_duration: float | None = None,
) -> SegmentPlan:
    """Build the segments the watch will play, in playback order.

    A book of mp3 files keeps each file. A file longer than ``max_duration``
    is cut into pieces of at most that length. An m4b is cut on its chapter
    markers, and a chapter piece longer than ``max_duration`` is split into
    equal parts. Anything else is refused.

    One segment never crosses two source files.

    Args:
        files: Source audio files in playback order.
        chapters: Chapter markers. Used for an m4b, ignored for mp3 files.
        max_duration: Longest mp3 file or m4b chapter piece, in seconds.
            Omit it and ``MAX_FILE_DURATION_SECONDS`` from the configuration
            is used.

    Returns:
        The cut list.

    Raises:
        ValueError: The item has no audio files, or ``max_duration`` is not
            positive.
        NotForWatch: The book is not mp3 files or an m4b with chapters.
    """
    if not files:
        raise ValueError("Item without audio files")

    suffixes = _suffixes(files)
    if suffixes == {".mp3"}:
        return _plan_mp3(files, _duration_limit(max_duration))
    if suffixes == {".m4b"}:
        return _plan_m4b(files, chapters, _duration_limit(max_duration))

    found = ", ".join(sorted(suffixes)) or "none"
    raise NotForWatch(f"only mp3 and m4b books are offered, found {found}")
