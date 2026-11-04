from __future__ import annotations

from dataclasses import dataclass


@dataclass(frozen=True)
class SourceFile:
    """One audio file of an Audiobookshelf item.

    Attributes:
        ino: Audiobookshelf's id for the file. Downloads are addressed by it,
            not by filename.
        filename: Name Audiobookshelf gives the file.
        duration: Length in seconds.
        size: Size in bytes.
    """

    ino: str
    filename: str
    duration: float
    size: int


@dataclass(frozen=True)
class Chapter:
    """One chapter marker, in absolute book time.

    Attributes:
        start: Start of the chapter, in seconds from the beginning of the book.
        end: End of the chapter, in the same clock.
        title: Chapter title shown on the watch.
    """

    start: float
    end: float
    title: str

    @property
    def duration(self) -> float:
        return self.end - self.start


@dataclass(frozen=True)
class Segment:
    """One track on the watch.

    ``source_start`` and ``source_end`` tell ffmpeg where to cut inside the
    source file. ``book_start`` is that same moment in absolute book time, so
    a playback position can be sent back to Audiobookshelf later.

    Attributes:
        index: Position of this track in the book, starting at 0.
        title: Title shown for the track.
        source_ino: Audiobookshelf file id the segment was cut from.
        source_start: Start of the cut in the source file, in seconds.
        source_end: End of the cut in the source file, in seconds.
        book_start: Start of the segment in absolute book time, in seconds.
    """

    index: int
    title: str
    source_ino: str
    source_start: float
    source_end: float
    book_start: float

    @property
    def duration(self) -> float:
        return self.source_end - self.source_start

    @property
    def filename(self) -> str:
        return f"{self.index:04d}.mp3"


@dataclass(frozen=True)
class SegmentPlan:
    """The cut list for one book.

    Attributes:
        segments: Segments in playback order.
        chapter_source: "chapters" when an m4b was cut on its markers,
            "files" when each mp3 file was kept whole.
        total_duration: Sum of the source files, in seconds.
    """

    segments: list[Segment]
    chapter_source: str  # "chapters" | "files"
    total_duration: float = 0.0
