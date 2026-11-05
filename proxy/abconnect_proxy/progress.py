"""Conversion between watch and Audiobookshelf coordinates."""

from __future__ import annotations

from dataclasses import dataclass

TOLERANCE = 0.5


@dataclass(frozen=True)
class Position:
    """Where the watch is inside a book.

    Attributes:
        segment: Segment index.
        offset: Seconds into that segment.
    """

    segment: int
    offset: float


def book_time(segments: list[dict], segment_index: int, offset: float) -> float:
    """Convert a watch position to absolute book time.

    Args:
        segments: Manifest entries, each with index, book_start and duration.
        segment_index: Segment the watch is in.
        offset: Seconds into that segment.

    Returns:
        Absolute book time in seconds. An index that is not in the list
        yields 0.
    """
    for entry in segments:
        if entry["index"] == segment_index:
            capped = max(0.0, min(offset, float(entry["duration"])))
            return round(float(entry["book_start"]) + capped, 3)
    return 0.0


def position(segments: list[dict], time_in_book: float) -> Position:
    """Convert an absolute book time to a watch position.

    Args:
        segments: Manifest entries in book order.
        time_in_book: Absolute book time, in seconds.

    Returns:
        The segment and the offset into it. An empty list yields segment 0
        at offset 0.
    """
    if not segments:
        return Position(0, 0.0)
    chosen = segments[0]
    for entry in segments:
        if float(entry["book_start"]) <= time_in_book + TOLERANCE:
            chosen = entry
        else:
            break
    offset = max(
        0.0, min(time_in_book - float(chosen["book_start"]), float(chosen["duration"]))
    )
    return Position(int(chosen["index"]), round(offset, 3))


def server_timestamp(progress: dict | None) -> float:
    """Read when Audiobookshelf last stored this position.

    Audiobookshelf reports lastUpdate in milliseconds. Values that are
    already in seconds are left as they are.

    Args:
        progress: JSON from the progress endpoint, or None when there is none.

    Returns:
        The timestamp in seconds, or 0 when there is no position.
    """
    if not progress:
        return 0.0
    raw = progress.get("lastUpdate") or progress.get("updatedAt") or 0
    try:
        value = float(raw)
    except (TypeError, ValueError):
        return 0.0
    return value / 1000.0 if value > 1e11 else value


def choose(
    *,
    watch_time: float,
    watch_ts: float,
    server_time: float,
    server_ts: float,
) -> tuple[str, float]:
    """Choose the listening position to keep.

    Times are seconds of absolute book time. Timestamps are unix seconds.
    The more recent timestamp wins. A tie goes to the watch: it was just
    listening, and the server only holds a position that was already sent.

    Args:
        watch_time: Absolute book time reported by the watch.
        watch_ts: When the watch observed that position.
        server_time: Absolute book time stored by Audiobookshelf.
        server_ts: When Audiobookshelf stored that position.

    Returns:
        ``("watch", watch_time)`` or ``("server", server_time)``.
    """
    if server_ts > watch_ts:
        return "server", server_time
    return "watch", watch_time
