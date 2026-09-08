"""Data models shared between ABS, segmentation and the watch."""

from __future__ import annotations

from dataclasses import dataclass, field
from enum import Enum


class Encoding(str, Enum):
    """Matches the watch's Media.ENCODING_* constants."""

    M4A = "m4a"
    MP3 = "mp3"

    @property
    def suffix(self) -> str:
        return f".{self.value}"


# ABS reports codecs, the watch knows containers. Anything not listed here
# cannot be played by the device and leads to a clear error instead of a file
# the player silently refuses.
#
# This is the gate on acceptable *source* codecs only. Which container a segment
# actually leaves in is decided later, in preparer._encode_for(), once the file
# has been probed — a conforming source keeps its own, a non-conforming one gets
# whatever TRANSCODE_TARGET says.
CODEC_TO_ENCODING = {
    "aac": Encoding.M4A,
    "mp4a": Encoding.M4A,
    "alac": Encoding.M4A,
    "mp3": Encoding.MP3,
    "mp3float": Encoding.MP3,
}


class UnsupportedCodec(Exception):
    def __init__(self, codec: str) -> None:
        self.codec = codec
        super().__init__(f"Codec '{codec}' is not supported by Connect IQ")


def encoding_for(codec: str) -> Encoding:
    try:
        return CODEC_TO_ENCODING[codec.lower().strip()]
    except KeyError:
        raise UnsupportedCodec(codec) from None


@dataclass(frozen=True)
class SourceFile:
    """An audio file of an ABS item."""

    ino: str
    filename: str
    duration: float
    size: int
    codec: str

    @property
    def encoding(self) -> Encoding:
        return encoding_for(self.codec)


@dataclass(frozen=True)
class Chapter:
    """Chapter marker in absolute book time."""

    start: float
    end: float
    title: str

    @property
    def duration(self) -> float:
        return self.end - self.start


@dataclass(frozen=True)
class Segment:
    """A track on the watch.

    Two coordinate systems: `source_*` tells ffmpeg what to cut,
    `book_start` allows a playback point to be converted back to absolute
    book time for ABS later.
    """

    index: int
    title: str
    source_ino: str
    source_start: float
    source_end: float
    book_start: float
    encoding: Encoding

    @property
    def duration(self) -> float:
        return self.source_end - self.source_start

    @property
    def filename(self) -> str:
        return f"{self.index:04d}{self.encoding.suffix}"


@dataclass(frozen=True)
class SegmentPlan:
    segments: list[Segment]
    chapter_source: str  # "chapters" | "grid"
    reason: str = ""  # why the fallback kicked in
    total_duration: float = 0.0

    @property
    def used_fallback(self) -> bool:
        return self.chapter_source == "grid"


@dataclass
class BookSummary:
    """What the watch needs to see about a book — deliberately minimal."""

    id: str
    title: str
    author: str
    duration: float
    status: str = "pending"
    progress: float = 0.0
    segment_count: int = 0
    error: str = ""
    unsupported: str = ""
    extra: dict = field(default_factory=dict)
