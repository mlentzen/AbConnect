import pytest

from abconnect_proxy.auth import FailureTracker, match_user, token_from_header
from abconnect_proxy.config import UserConfig

ALICE = UserConfig(
    "alice",
    ("erster-token-1234", "zweiter-token-123"),
    "https://a.example",
    "k" * 20,
    "Garmin",
)
BOB = UserConfig("bob", ("bobs-token-123456",), "https://b.example", "b" * 20, "Garmin")
USERS = (ALICE, BOB)


class TestBearer:
    def test_maps_every_token_to_its_user(self):
        assert match_user(ALICE.tokens[0], USERS) is ALICE
        assert match_user(ALICE.tokens[1], USERS) is ALICE  # rotation
        assert match_user(BOB.tokens[0], USERS) is BOB

    def test_rejects_anything_else(self):
        assert match_user("erster-token-1233", USERS) is None
        assert match_user("", USERS) is None
        assert match_user(ALICE.tokens[0], ()) is None

    def test_non_ascii_input_is_rejected_not_crashed(self):
        assert match_user("tökén-mit-umlaut-1", USERS) is None

    @pytest.mark.parametrize(
        "header, expected",
        [
            ("Bearer abc", "abc"),
            ("bearer abc", "abc"),
            ("Basic abc", None),
            ("Bearer ", None),
            ("abc", None),
            (None, None),
        ],
    )
    def test_parses_the_header(self, header, expected):
        assert token_from_header(header) == expected


class TestFailureTracker:
    def test_locks_after_repeated_failures(self):
        tracker = FailureTracker(threshold=3, lockout_seconds=60)
        for _ in range(3):
            tracker.record_failure("1.2.3.4", now=1000)
        assert tracker.locked("1.2.3.4", now=1000) == pytest.approx(60)

    def test_a_success_clears_the_slate(self):
        tracker = FailureTracker(threshold=3)
        tracker.record_failure("1.2.3.4", now=1000)
        tracker.record_failure("1.2.3.4", now=1000)
        tracker.record_success("1.2.3.4")
        tracker.record_failure("1.2.3.4", now=1000)
        assert tracker.locked("1.2.3.4", now=1000) == 0

    def test_clients_are_tracked_separately(self):
        tracker = FailureTracker(threshold=2, lockout_seconds=60)
        tracker.record_failure("1.1.1.1", now=1000)
        tracker.record_failure("1.1.1.1", now=1000)
        assert tracker.locked("1.1.1.1", now=1000) > 0
        assert tracker.locked("2.2.2.2", now=1000) == 0

    def test_the_lock_expires(self):
        tracker = FailureTracker(threshold=2, lockout_seconds=60)
        tracker.record_failure("1.1.1.1", now=1000)
        tracker.record_failure("1.1.1.1", now=1000)
        assert tracker.locked("1.1.1.1", now=1061) == 0

    def test_forgets_clients_with_nothing_recent_against_them(self):
        tracker = FailureTracker(threshold=2, lockout_seconds=60, max_clients=10)
        for n in range(10):
            tracker.record_failure(f"10.0.0.{n}", now=1000)
        tracker.record_failure("10.0.0.1", now=1000)  # locked until 1060
        tracker.record_failure("9.9.9.9", now=1100)
        assert tracker.tracked() == 1

    def test_pruning_keeps_a_live_lock(self):
        tracker = FailureTracker(threshold=2, lockout_seconds=60, max_clients=10)
        for n in range(10):
            tracker.record_failure(f"10.0.0.{n}", now=1000)
        tracker.record_failure("10.0.0.1", now=1000)
        tracker.record_failure("9.9.9.9", now=1010)
        assert tracker.locked("10.0.0.1", now=1010) == pytest.approx(50)
