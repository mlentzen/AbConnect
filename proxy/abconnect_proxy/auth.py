"""Access control for the watch -> proxy path."""

from __future__ import annotations

import hmac
import time
from collections import defaultdict
from collections.abc import Iterable
from dataclasses import dataclass, field

from .config import UserConfig


def _same(a: str, b: str) -> bool:
    # Bytes, not str: compare_digest raises on non-ASCII text, and a header or
    # query string can carry anything.
    return hmac.compare_digest(a.encode(), b.encode())


def match_user(presented: str, users: Iterable[UserConfig]) -> UserConfig | None:
    """Find the user who owns the presented token.

    Comparison does not stop at the first hit. Every token of every user is
    checked, so the runtime reveals neither which token matched nor whose
    it was.

    Args:
        presented: Token from the request.
        users: Configured users.

    Returns:
        The matching user, or None.
    """
    match = None
    for user in users:
        for token in user.tokens:
            if _same(presented, token):
                match = user
    return match


def token_from_header(header: str | None) -> str | None:
    """Read the credential from an Authorization header.

    Args:
        header: Value of the Authorization header, or None when the request
            has none.

    Returns:
        The bearer token. None when the header is missing, the scheme is
        not Bearer, or Bearer has no token after it.
    """
    if not header:
        return None
    scheme, _, value = header.partition(" ")
    if scheme.lower() != "bearer" or not value.strip():
        return None
    return value.strip()


# --- Backoff -----------------------------------------------------------------


@dataclass
class FailureTracker:
    """Throttle guessing attempts without locking out a legitimate client.

    Attributes:
        threshold: Failures inside the lockout window before an address is
            locked.
        lockout_seconds: How long a locked address stays locked, and how far
            back failures are counted.
        max_clients: Maximum number of addresses to remember.
            When the number of remembered addresses exceeds this, the oldest
            ones are forgotten.
    """

    threshold: int = 5
    lockout_seconds: float = 60.0
    max_clients: int = 1024
    _failures: dict[str, list[float]] = field(default_factory=lambda: defaultdict(list))
    _locked_until: dict[str, float] = field(default_factory=dict)

    def tracked(self) -> int:
        """Count the addresses currently remembered.

        Returns:
            How many addresses have a recent failure or an active lock.
        """
        return len(self._failures.keys() | self._locked_until.keys())

    def _prune(self, now: float) -> None:
        self._failures = defaultdict(
            list,
            {
                c: times
                for c, times in self._failures.items()
                if times and now - times[-1] < self.lockout_seconds
            },
        )
        self._locked_until = {
            c: until for c, until in self._locked_until.items() if until > now
        }

    def locked(self, client: str, now: float | None = None) -> float:
        """Report how long this address stays locked.

        Args:
            client: Client address, as the request reports it.
            now: Clock to compare against. Omit it to use the current time.

        Returns:
            Remaining lockout in seconds, or 0 when the address is open.
        """
        now = time.time() if now is None else now
        until = self._locked_until.get(client, 0.0)
        return max(0.0, until - now)

    def record_failure(self, client: str, now: float | None = None) -> None:
        now = time.time() if now is None else now
        if self.tracked() >= self.max_clients:
            self._prune(now)
        recent = [t for t in self._failures[client] if now - t < self.lockout_seconds]
        recent.append(now)
        self._failures[client] = recent
        if len(recent) >= self.threshold:
            self._locked_until[client] = now + self.lockout_seconds
            self._failures[client] = []

    def record_success(self, client: str) -> None:
        self._failures.pop(client, None)
        self._locked_until.pop(client, None)
