"""Datenmodelle, die zwischen ABS, Segmentierung und Uhr geteilt werden."""

from __future__ import annotations

from dataclasses import dataclass, field
from enum import Enum


class Encoding(str, Enum):
    """Entspricht den Media.ENCODING_*-Konstanten der Uhr."""

    M4A = "m4a"
    MP3 = "mp3"

    @property
    def suffix(self) -> str:
        return f".{self.value}"


# ABS meldet Codecs, die Uhr kennt Container. Alles, was hier nicht auftaucht,
# kann das Gerät nicht abspielen und führt zu einem klaren Fehler statt zu einer
# Datei, die der Player stumm verweigert.
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
        super().__init__(f"Codec '{codec}' wird von Connect IQ nicht unterstützt")


def encoding_for(codec: str) -> Encoding:
    try:
        return CODEC_TO_ENCODING[codec.lower().strip()]
    except KeyError:
        raise UnsupportedCodec(codec) from None


@dataclass(frozen=True)
class SourceFile:
    """Eine Audiodatei eines ABS-Items."""

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
    """Kapitelmarke in absoluter Buchzeit."""

    start: float
    end: float
    title: str

    @property
    def duration(self) -> float:
        return self.end - self.start


@dataclass(frozen=True)
class Segment:
    """Ein Track auf der Uhr.

    Zwei Koordinatensysteme: `source_*` sagt ffmpeg, was zu schneiden ist,
    `book_start` erlaubt später die Rückrechnung eines Abspielpunkts auf die
    absolute Buchzeit für ABS.
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
    reason: str = ""  # warum der Fallback griff
    total_duration: float = 0.0

    @property
    def used_fallback(self) -> bool:
        return self.chapter_source == "grid"


@dataclass
class BookSummary:
    """Was die Uhr über ein Buch sehen muss — bewusst schmal."""

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
