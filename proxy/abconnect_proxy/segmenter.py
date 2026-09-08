"""Chapters -> segment plan.

Pure computation without IO so it stays quick to test against real chapter
lists. Four steps, in this order:

1. validate chapters, otherwise a 15-minute grid as fallback
2. cut at file boundaries — a segment never spans two source files
3. merge segments that are too short
4. split segments that are too long

Afterwards, number the titles where one chapter produced several segments.
"""

from __future__ import annotations

import math
from dataclasses import dataclass

from .models import Chapter, Segment, SegmentPlan, SourceFile

TOLERANCE = 0.5
MIN_COVERAGE = 0.9


@dataclass
class _Piece:
    """Intermediate state: a piece of a specific source file."""

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
    """An empty string means usable, otherwise the reason for the fallback."""
    if not chapters:
        return "no chapter markers present"

    ordered = sorted(chapters, key=lambda c: c.start)
    if ordered != list(chapters):
        return "chapters are not sorted chronologically"

    for chapter in ordered:
        if chapter.duration <= 0:
            return f"chapter '{chapter.title}' has no duration"
    for previous, current in zip(ordered, ordered[1:]):
        if current.start < previous.end - TOLERANCE:
            return f"chapters overlap at '{current.title}'"

    if ordered[0].start < -TOLERANCE:
        return "first chapter begins before the start of the book"
    if ordered[-1].end > total_duration + TOLERANCE:
        return "chapters extend beyond the book duration"

    if len(ordered) == 1:
        return "only one chapter across the whole book"

    covered = sum(c.duration for c in ordered)
    if total_duration > 0 and covered / total_duration < MIN_COVERAGE:
        return f"chapters cover only {covered / total_duration:.0%} of the book"

    return ""


def _grid(total_duration: float, target: int) -> list[Chapter]:
    count = max(1, math.ceil(total_duration / target))
    length = total_duration / count
    return [
        Chapter(start=i * length, end=min((i + 1) * length, total_duration), title=f"Section {i + 1}")
        for i in range(count)
    ]


def _snap(chapters: list[Chapter], total_duration: float) -> list[Chapter]:
    """Close edge gaps so no audio is lost between the segments."""
    snapped = list(chapters)
    first, last = snapped[0], snapped[-1]
    snapped[0] = Chapter(0.0, first.end, first.title)
    snapped[-1] = Chapter(snapped[-1].start, total_duration, last.title)
    # Add gaps between chapters to the preceding one.
    for i in range(len(snapped) - 1):
        if snapped[i + 1].start > snapped[i].end + TOLERANCE:
            snapped[i] = Chapter(snapped[i].start, snapped[i + 1].start, snapped[i].title)
    return snapped


def _split_at_file_boundaries(chapters: list[Chapter], files: list[SourceFile]) -> list[_Piece]:
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


def _merge_short(pieces: list[_Piece], minimum: int) -> list[_Piece]:
    """Attach pieces that are too short to their neighbor — only within the same file."""
    merged: list[_Piece] = []
    for piece in pieces:
        if (
            merged
            and merged[-1].duration < minimum
            and merged[-1].file_index == piece.file_index
        ):
            # The predecessor is too short: it swallows the current piece and
            # keeps its title — so the segment is named after the first chapter in it.
            merged[-1].source_end = piece.source_end
            continue
        merged.append(piece)

    # A last piece of a file that is too short cannot grow forwards and is
    # therefore appended backwards.
    result: list[_Piece] = []
    for piece in merged:
        if (
            piece.duration < minimum
            and result
            and result[-1].file_index == piece.file_index
        ):
            result[-1].source_end = piece.source_end
            continue
        result.append(piece)
    return result


def _split_long(pieces: list[_Piece], maximum: int, target: int) -> list[_Piece]:
    result: list[_Piece] = []
    for piece in pieces:
        if piece.duration <= maximum:
            result.append(piece)
            continue
        parts = math.ceil(piece.duration / target)
        length = piece.duration / parts
        for part in range(parts):
            start = piece.source_start + part * length
            end = piece.source_start + (part + 1) * length if part < parts - 1 else piece.source_end
            result.append(
                _Piece(
                    file_index=piece.file_index,
                    source_start=start,
                    source_end=end,
                    book_start=piece.book_start + (start - piece.source_start),
                    title=piece.title,
                    chapter_index=piece.chapter_index,
                )
            )
    return result


def _number_titles(pieces: list[_Piece]) -> None:
    """'Chapter 3' becomes 'Chapter 3 (1/3)' where one chapter produced several segments."""
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


def plan_segments(
    files: list[SourceFile],
    chapters: list[Chapter],
    *,
    target_seconds: int,
    min_seconds: int,
    max_seconds: int,
) -> SegmentPlan:
    if not files:
        raise ValueError("Item without audio files")

    total_duration = sum(f.duration for f in files)
    reason = validate_chapters(chapters, total_duration)
    if reason:
        working = _grid(total_duration, target_seconds)
        chapter_source = "grid"
    else:
        working = _snap(chapters, total_duration)
        chapter_source = "chapters"

    pieces = _split_at_file_boundaries(working, files)
    pieces = _merge_short(pieces, min_seconds)
    pieces = _split_long(pieces, max_seconds, target_seconds)
    _number_titles(pieces)

    segments = [
        Segment(
            index=index,
            title=piece.title,
            source_ino=files[piece.file_index].ino,
            source_start=round(piece.source_start, 3),
            source_end=round(piece.source_end, 3),
            book_start=round(piece.book_start, 3),
            encoding=files[piece.file_index].encoding,
        )
        for index, piece in enumerate(pieces)
    ]
    return SegmentPlan(
        segments=segments,
        chapter_source=chapter_source,
        reason=reason,
        total_duration=total_duration,
    )


def locate(segments: list[Segment], book_time: float) -> tuple[int, float]:
    """Absolute book time -> (segment index, offset). For the way back from ABS."""
    if not segments:
        return 0, 0.0
    chosen = segments[0]
    for segment in segments:
        if segment.book_start <= book_time + TOLERANCE:
            chosen = segment
        else:
            break
    offset = max(0.0, min(book_time - chosen.book_start, chosen.duration))
    return chosen.index, round(offset, 3)
