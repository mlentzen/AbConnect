import pytest

from abconnect_proxy.progress import Position, book_time, position, reconcile, server_timestamp

SEGMENTS = [
    {"index": 0, "book_start": 0.0, "duration": 900.0},
    {"index": 1, "book_start": 900.0, "duration": 900.0},
    {"index": 2, "book_start": 1800.0, "duration": 600.0},
]


class TestMapping:
    def test_segment_offset_to_book_time(self):
        assert book_time(SEGMENTS, 1, 120) == 1020.0

    def test_offset_beyond_the_segment_is_capped(self):
        assert book_time(SEGMENTS, 2, 99999) == 2400.0

    def test_unknown_segment_falls_back_to_the_start(self):
        assert book_time(SEGMENTS, 42, 100) == 0.0

    def test_book_time_to_segment_offset(self):
        assert position(SEGMENTS, 1020) == Position(1, 120.0)
        assert position(SEGMENTS, 0) == Position(0, 0.0)

    def test_round_trip_is_stable(self):
        for index, offset in ((0, 0.0), (1, 450.0), (2, 599.0)):
            assert position(SEGMENTS, book_time(SEGMENTS, index, offset)) == Position(index, offset)

    def test_empty_plan_yields_the_start(self):
        assert position([], 500) == Position(0, 0.0)


class TestServerTimestamp:
    def test_reads_milliseconds(self):
        assert server_timestamp({"lastUpdate": 1_700_000_000_000}) == 1_700_000_000.0

    def test_accepts_seconds(self):
        assert server_timestamp({"lastUpdate": 1_700_000_000}) == 1_700_000_000.0

    @pytest.mark.parametrize("payload", [None, {}, {"lastUpdate": "kaputt"}])
    def test_missing_or_broken_means_zero(self, payload):
        assert server_timestamp(payload) == 0.0


class TestReconcile:
    def test_newer_server_position_wins(self):
        assert reconcile(watch_time=100, watch_ts=10, server_time=500, server_ts=20) == ("server", 500)

    def test_newer_watch_position_wins(self):
        assert reconcile(watch_time=100, watch_ts=30, server_time=500, server_ts=20) == ("watch", 100)

    def test_a_tie_goes_to_the_watch(self):
        assert reconcile(watch_time=100, watch_ts=20, server_time=500, server_ts=20) == ("watch", 100)
