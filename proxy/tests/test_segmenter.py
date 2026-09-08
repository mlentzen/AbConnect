from abconnect_proxy.models import Chapter, Encoding, SourceFile
from abconnect_proxy.segmenter import locate, plan_segments, validate_chapters

PARAMS = {"target_seconds": 900, "min_seconds": 180, "max_seconds": 1500}


def m4b(duration: float, ino: str = "1") -> SourceFile:
    return SourceFile(ino=ino, filename=f"{ino}.m4b", duration=duration, size=1000, codec="aac")


def chapters(*spans: tuple[float, float]) -> list[Chapter]:
    return [Chapter(start, end, f"Kapitel {i + 1}") for i, (start, end) in enumerate(spans)]


class TestValidation:
    def test_accepts_sane_chapters(self):
        assert validate_chapters(chapters((0, 600), (600, 1200)), 1200) == ""

    def test_rejects_empty(self):
        assert "keine Kapitelmarken" in validate_chapters([], 1200)

    def test_rejects_single_chapter_spanning_book(self):
        assert "nur ein Kapitel" in validate_chapters(chapters((0, 1200)), 1200)

    def test_rejects_overlap(self):
        assert "überlappen" in validate_chapters(chapters((0, 700), (600, 1200)), 1200)

    def test_rejects_zero_length(self):
        assert "keine Dauer" in validate_chapters(chapters((0, 600), (600, 600), (600, 1200)), 1200)

    def test_rejects_beyond_duration(self):
        assert "Buchdauer" in validate_chapters(chapters((0, 600), (600, 9999)), 1200)

    def test_rejects_unsorted(self):
        assert "chronologisch" in validate_chapters(chapters((600, 1200), (0, 600)), 1200)

    def test_rejects_sparse_coverage(self):
        # Marken nur am Anfang: der Rest des Buchs wäre unsegmentiert.
        assert "decken nur" in validate_chapters(chapters((0, 50), (50, 100)), 1200)


class TestPlanning:
    def test_uses_chapters_when_usable(self):
        plan = plan_segments([m4b(1800)], chapters((0, 900), (900, 1800)), **PARAMS)
        assert plan.chapter_source == "chapters"
        assert [s.title for s in plan.segments] == ["Kapitel 1", "Kapitel 2"]

    def test_falls_back_to_grid(self):
        plan = plan_segments([m4b(3600)], [], **PARAMS)
        assert plan.used_fallback
        assert "keine Kapitelmarken" in plan.reason
        assert len(plan.segments) == 4
        assert all(s.duration == 900 for s in plan.segments)

    def test_merges_short_chapters_forward(self):
        plan = plan_segments([m4b(1200)], chapters((0, 60), (60, 1200)), **PARAMS)
        assert len(plan.segments) == 1
        assert plan.segments[0].title == "Kapitel 1"
        assert plan.segments[0].duration == 1200

    def test_merges_short_trailing_chapter_backward(self):
        plan = plan_segments([m4b(1260)], chapters((0, 1200), (1200, 1260)), **PARAMS)
        assert len(plan.segments) == 1
        assert plan.segments[0].source_end == 1260

    def test_splits_overlong_chapter_and_numbers_titles(self):
        plan = plan_segments([m4b(3000)], chapters((0, 1500), (1500, 3000)), **PARAMS)
        # 1500s liegt genau auf max und bleibt daher ungeteilt.
        assert len(plan.segments) == 2
        plan = plan_segments([m4b(3600)], chapters((0, 1800), (1800, 3600)), **PARAMS)
        assert [s.title for s in plan.segments] == [
            "Kapitel 1 (1/2)", "Kapitel 1 (2/2)", "Kapitel 2 (1/2)", "Kapitel 2 (2/2)",
        ]
        assert all(s.duration <= 1500 for s in plan.segments)

    def test_no_segment_spans_two_files(self):
        files = [m4b(1000, "a"), m4b(1000, "b")]
        plan = plan_segments(files, chapters((0, 900), (900, 2000)), **PARAMS)
        for segment in plan.segments:
            assert segment.source_end <= 1000 + 1e-6
        assert {s.source_ino for s in plan.segments} == {"a", "b"}

    def test_segments_are_gapless_and_cover_the_book(self):
        files = [m4b(1000, "a"), m4b(1000, "b")]
        plan = plan_segments(files, chapters((0, 700), (700, 1400), (1400, 2000)), **PARAMS)
        assert sum(s.duration for s in plan.segments) == 2000
        expected_start = 0.0
        for segment in plan.segments:
            assert segment.book_start == expected_start
            expected_start += segment.duration

    def test_snaps_leading_gap_so_no_audio_is_lost(self):
        plan = plan_segments([m4b(1800)], chapters((30, 900), (900, 1800)), **PARAMS)
        assert plan.segments[0].source_start == 0.0
        assert sum(s.duration for s in plan.segments) == 1800

    def test_carries_encoding_from_source(self):
        mp3 = SourceFile(ino="1", filename="a.mp3", duration=1800, size=1, codec="mp3")
        plan = plan_segments([mp3], [], **PARAMS)
        assert all(s.encoding is Encoding.MP3 for s in plan.segments)
        assert plan.segments[0].filename == "0000.mp3"

    def test_short_book_yields_one_segment(self):
        plan = plan_segments([m4b(120)], [], **PARAMS)
        assert len(plan.segments) == 1
        assert plan.segments[0].duration == 120


class TestLocate:
    def test_maps_book_time_to_segment_and_offset(self):
        plan = plan_segments([m4b(3600)], [], **PARAMS)
        assert locate(plan.segments, 0) == (0, 0.0)
        assert locate(plan.segments, 950) == (1, 50.0)
        assert locate(plan.segments, 3599) == (3, 899.0)

    def test_clamps_beyond_the_end(self):
        plan = plan_segments([m4b(3600)], [], **PARAMS)
        index, offset = locate(plan.segments, 99999)
        assert index == 3
        assert offset == 900.0
