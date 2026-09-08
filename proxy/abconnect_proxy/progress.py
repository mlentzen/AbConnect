"""Umrechnung zwischen Uhr- und ABS-Koordinaten.

Die Uhr kennt nur (Segmentindex, Offset). Absolute Buchzeiten entstehen erst
hier — so bleibt die Gerätelogik klein und die Segmentierung serverseitig
änderbar, ohne gespeicherte Positionen zu entwerten.
"""

from __future__ import annotations

from dataclasses import dataclass

TOLERANCE = 0.5


@dataclass(frozen=True)
class Position:
    segment: int
    offset: float


def book_time(segments: list[dict], segment_index: int, offset: float) -> float:
    """(Segment, Offset) -> absolute Buchzeit."""
    for entry in segments:
        if entry["index"] == segment_index:
            capped = max(0.0, min(offset, float(entry["duration"])))
            return round(float(entry["book_start"]) + capped, 3)
    return 0.0


def position(segments: list[dict], time_in_book: float) -> Position:
    """Absolute Buchzeit -> (Segment, Offset)."""
    if not segments:
        return Position(0, 0.0)
    chosen = segments[0]
    for entry in segments:
        if float(entry["book_start"]) <= time_in_book + TOLERANCE:
            chosen = entry
        else:
            break
    offset = max(0.0, min(time_in_book - float(chosen["book_start"]), float(chosen["duration"])))
    return Position(int(chosen["index"]), round(offset, 3))


def server_timestamp(progress: dict | None) -> float:
    """ABS meldet lastUpdate in Millisekunden — hier in Sekunden."""
    if not progress:
        return 0.0
    raw = progress.get("lastUpdate") or progress.get("updatedAt") or 0
    try:
        value = float(raw)
    except (TypeError, ValueError):
        return 0.0
    return value / 1000.0 if value > 1e11 else value


def reconcile(
    *,
    watch_time: float,
    watch_ts: float,
    server_time: float,
    server_ts: float,
) -> tuple[str, float]:
    """Jüngerer Zeitstempel gewinnt.

    Gleichstand geht an die Uhr: sie hat gerade gehört, der Server hält nur
    einen bereits übertragenen Stand.
    """
    if server_ts > watch_ts:
        return "server", server_time
    return "watch", watch_time
