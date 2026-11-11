import pytest

from abconnect_proxy.models import Chapter, SourceFile
from abconnect_proxy.segmenter import NotForWatch, plan_segments


def m4b(duration: float, ino: str = "1") -> SourceFile:
    return SourceFile(ino=ino, filename=f"{ino}.m4b", duration=duration, size=1000)


def mp3(duration: float, ino: str = "1", filename: str | None = None) -> SourceFile:
    return SourceFile(
        ino=ino,
        filename=filename or f"{ino}.mp3",
        duration=duration,
        size=1000,
    )


def chapters(*spans: tuple[float, float]) -> list[Chapter]:
    return [
        Chapter(start, end, f"Chapter {i + 1}") for i, (start, end) in enumerate(spans)
    ]


class TestM4b:
    def test_uses_chapters(self):
        plan = plan_segments([m4b(1800)], chapters((0, 900), (900, 1800)))
        assert plan.chapter_source == "chapters"
        assert [s.title for s in plan.segments] == ["Chapter 1", "Chapter 2"]
        assert all(s.filename.endswith(".mp3") for s in plan.segments)

    def test_refuses_a_book_without_chapters(self):
        with pytest.raises(NotForWatch, match="no chapter markers"):
            plan_segments([m4b(3600)], [])

    def test_refuses_chapters_that_cannot_be_cut(self):
        with pytest.raises(NotForWatch, match="overlap"):
            plan_segments([m4b(1200)], chapters((0, 700), (600, 1200)))

    def test_refuses_a_zero_length_chapter(self):
        with pytest.raises(NotForWatch, match="no duration"):
            plan_segments([m4b(1200)], chapters((0, 600), (600, 600), (600, 1200)))

    def test_refuses_chapters_past_the_book(self):
        with pytest.raises(NotForWatch, match="book duration"):
            plan_segments([m4b(1200)], chapters((0, 600), (600, 9999)))

    def test_refuses_unsorted_chapters(self):
        with pytest.raises(NotForWatch, match="chronologically"):
            plan_segments([m4b(1200)], chapters((600, 1200), (0, 600)))

    def test_keeps_a_short_chapter(self):
        plan = plan_segments([m4b(1200)], chapters((0, 60), (60, 1200)))
        assert [s.duration for s in plan.segments] == [60, 1140]
        assert [s.title for s in plan.segments] == ["Chapter 1", "Chapter 2"]

    def test_a_chapter_at_the_limit_stays_whole(self):
        plan = plan_segments([m4b(7200)], chapters((0, 3600), (3600, 7200)))
        assert [s.duration for s in plan.segments] == [3600, 3600]
        assert [s.title for s in plan.segments] == ["Chapter 1", "Chapter 2"]

    def test_splits_a_long_chapter_into_equal_parts(self):
        plan = plan_segments([m4b(7200)], chapters((0, 1800), (1800, 7200)))
        assert [
            (s.title, s.source_start, s.duration, s.book_start) for s in plan.segments
        ] == [
            ("Chapter 1", 0.0, 1800, 0.0),
            ("Chapter 2 (1/2)", 1800.0, 2700, 1800.0),
            ("Chapter 2 (2/2)", 4500.0, 2700, 4500.0),
        ]

    def test_equal_parts_stay_inside_one_file(self):
        files = [m4b(150, "a"), m4b(50, "b")]
        plan = plan_segments(files, chapters((0, 200)), 80)
        assert [
            (s.title, s.source_ino, s.source_start, s.duration) for s in plan.segments
        ] == [
            ("Chapter 1 (1/3)", "a", 0.0, 75),
            ("Chapter 1 (2/3)", "a", 75.0, 75),
            ("Chapter 1 (3/3)", "b", 0.0, 50),
        ]

    def test_one_chapter_is_one_segment(self):
        plan = plan_segments([m4b(1200)], chapters((0, 1200)))
        assert len(plan.segments) == 1
        assert plan.segments[0].duration == 1200

    def test_no_segment_spans_two_files(self):
        files = [m4b(1000, "a"), m4b(1000, "b")]
        plan = plan_segments(files, chapters((0, 900), (900, 2000)))
        for segment in plan.segments:
            assert segment.source_end <= 1000 + 1e-6
        assert {s.source_ino for s in plan.segments} == {"a", "b"}
        assert [s.title for s in plan.segments] == [
            "Chapter 1",
            "Chapter 2 (1/2)",
            "Chapter 2 (2/2)",
        ]

    def test_segments_are_gapless_and_cover_the_book(self):
        files = [m4b(1000, "a"), m4b(1000, "b")]
        plan = plan_segments(files, chapters((0, 700), (700, 1400), (1400, 2000)))
        assert sum(s.duration for s in plan.segments) == 2000
        expected_start = 0.0
        for segment in plan.segments:
            assert segment.book_start == expected_start
            expected_start += segment.duration

    def test_snaps_leading_gap_so_no_audio_is_lost(self):
        plan = plan_segments([m4b(1800)], chapters((30, 900), (900, 1800)))
        assert plan.segments[0].source_start == 0.0
        assert sum(s.duration for s in plan.segments) == 1800


class TestMp3:
    def test_keeps_each_file_whole(self):
        files = [mp3(400, "a", "01 Intro.mp3"), mp3(800, "b", "02 Rest.mp3")]
        plan = plan_segments(files, chapters((0, 100), (100, 1200)))
        assert plan.chapter_source == "files"
        assert [
            (s.title, s.source_start, s.duration, s.book_start) for s in plan.segments
        ] == [
            ("01 Intro", 0.0, 400, 0.0),
            ("02 Rest", 0.0, 800, 400),
        ]
        assert plan.segments[0].filename == "0000.mp3"

    def test_a_file_within_the_limit_stays_whole(self):
        plan = plan_segments([mp3(3600, filename="whole.mp3")], [])
        assert len(plan.segments) == 1
        assert plan.segments[0].duration == 3600
        assert plan.segments[0].title == "whole"

    def test_split_of_large_files(self):
        """Split large files into smaller more manageable chunks. This defaults to anything over 1 hour."""
        plan = plan_segments([mp3(7200, filename="whole.mp3")], [])
        assert [
            (s.title, s.source_start, s.duration, s.book_start) for s in plan.segments
        ] == [
            ("whole-00.mp3", 0.0, 3600, 0.0),
            ("whole-01.mp3", 3600, 3600, 3600),
        ]

    def test_split_multiple_large_files(self):
        """Split multiple large files into smaller more manageable chunks. This defaults to anything over 1 hour."""
        files = [
            mp3(7200, "a", "whole1.mp3"),
            mp3(7200, "b", "whole2.mp3"),
            mp3(360, "c", "short.mp3"),
        ]
        plan = plan_segments(files, [])
        assert [
            (s.title, s.duration, s.book_start, s.source_ino) for s in plan.segments
        ] == [
            ("whole1-00.mp3", 3600, 0.0, "a"),
            ("whole1-01.mp3", 3600, 3600, "a"),
            ("whole2-00.mp3", 3600, 7200, "b"),
            ("whole2-01.mp3", 3600, 10800, "b"),
            ("short", 360, 14400, "c"),
        ]

    def test_splits_only_past_the_given_limit(self):
        whole = plan_segments([mp3(100, filename="fit.mp3")], [], 100)
        assert [(s.title, s.duration) for s in whole.segments] == [("fit", 100)]

        plan = plan_segments([mp3(100, filename="whole.mp3")], [], 40)
        assert [(s.title, s.source_start, s.duration) for s in plan.segments] == [
            ("whole-00.mp3", 0.0, 40),
            ("whole-01.mp3", 40.0, 40),
            ("whole-02.mp3", 80.0, 20),
        ]


class TestRefused:
    def test_refuses_another_container(self):
        other = SourceFile(ino="1", filename="book.m4a", duration=10, size=1)
        with pytest.raises(NotForWatch, match="m4a"):
            plan_segments([other], chapters((0, 10)))

    def test_refuses_a_mix_of_mp3_and_m4b(self):
        with pytest.raises(NotForWatch, match="only mp3 and m4b"):
            plan_segments([mp3(10), m4b(10, "2")], [])

    def test_refuses_an_item_without_files(self):
        with pytest.raises(ValueError):
            plan_segments([], [])
