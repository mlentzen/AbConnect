import time

import pytest

from abconnect_proxy.auth import FailureTracker, sign_cover, token_from_header, verify_cover, verify_token

TOKENS = ("erster-token-1234", "zweiter-token-123")


class TestBearer:
    def test_accepts_any_configured_token(self):
        assert verify_token(TOKENS[0], TOKENS)
        assert verify_token(TOKENS[1], TOKENS)

    def test_rejects_anything_else(self):
        assert not verify_token("erster-token-1233", TOKENS)
        assert not verify_token("", TOKENS)
        assert not verify_token(TOKENS[0], ())

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


class TestCoverSignature:
    def test_round_trip(self):
        expires = int(time.time()) + 600
        assert verify_cover("li_a", expires, sign_cover("li_a", expires, TOKENS[0]), TOKENS)

    def test_is_bound_to_the_book(self):
        expires = int(time.time()) + 600
        assert not verify_cover("li_b", expires, sign_cover("li_a", expires, TOKENS[0]), TOKENS)

    def test_expires(self):
        past = int(time.time()) - 1
        assert not verify_cover("li_a", past, sign_cover("li_a", past, TOKENS[0]), TOKENS)

    def test_an_old_key_still_validates_during_rotation(self):
        expires = int(time.time()) + 600
        signature = sign_cover("li_a", expires, TOKENS[1])
        assert verify_cover("li_a", expires, signature, TOKENS)

    def test_signature_carries_no_token_material(self):
        expires = int(time.time()) + 600
        signature = sign_cover("li_a", expires, TOKENS[0])
        assert TOKENS[0] not in signature


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
