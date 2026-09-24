"""Pairing: the token typed on a phone, delivered to the watch.

A side-loaded Connect IQ app gets no settings page in Garmin Connect, and a
token typed letter by letter on five buttons is nobody's idea of setup. So the
watch asks for a short code, shows it, and polls; the person opens /pair on the
phone, enters the code and pastes the token; the next poll hands the token to
the watch — once.

Nothing is granted here that was not already held: the phone has to present a
token that is valid on its own. Pairing only moves it onto the watch. Codes are
short-lived, few at a time, and guessing them runs into the same backoff as
guessing tokens.
"""

from __future__ import annotations

import secrets
import time
from dataclasses import dataclass

# No 0/O, 1/I: the code is read off a watch face and typed on a phone.
ALPHABET = "ABCDEFGHJKLMNPQRSTUVWXYZ23456789"
CODE_LENGTH = 6
CODE_TTL_SECONDS = 600.0
# One household pairs one watch at a time; this only bounds memory against
# someone requesting codes in a loop.
MAX_PENDING = 64


@dataclass
class _Pending:
    created: float
    token: str | None = None


class PairingFull(Exception):
    """Too many codes are open at once."""


class PairingRegistry:
    def __init__(self, ttl: float = CODE_TTL_SECONDS, max_pending: int = MAX_PENDING) -> None:
        self.ttl = ttl
        self.max_pending = max_pending
        self._codes: dict[str, _Pending] = {}

    def _prune(self, now: float) -> None:
        self._codes = {c: p for c, p in self._codes.items() if now - p.created < self.ttl}

    def start(self, now: float | None = None) -> str:
        now = time.time() if now is None else now
        self._prune(now)
        if len(self._codes) >= self.max_pending:
            raise PairingFull
        while True:
            code = "".join(secrets.choice(ALPHABET) for _ in range(CODE_LENGTH))
            if code not in self._codes:
                break
        self._codes[code] = _Pending(created=now)
        return code

    @staticmethod
    def normalize(code: str) -> str:
        """Phones capitalise, autocorrect and insert spaces; the code survives that."""
        return "".join(code.split()).upper()

    def pending(self, code: str, now: float | None = None) -> bool:
        now = time.time() if now is None else now
        self._prune(now)
        return self.normalize(code) in self._codes

    def complete(self, code: str, token: str, now: float | None = None) -> bool:
        """Attaches the token to an open code. False when the code is unknown or expired."""
        now = time.time() if now is None else now
        self._prune(now)
        entry = self._codes.get(self.normalize(code))
        if entry is None:
            return False
        entry.token = token
        return True

    def poll(self, code: str, now: float | None = None) -> tuple[bool, str | None]:
        """(known, token). The token is handed out exactly once, then the code is gone."""
        now = time.time() if now is None else now
        self._prune(now)
        code = self.normalize(code)
        entry = self._codes.get(code)
        if entry is None:
            return False, None
        if entry.token is None:
            return True, None
        del self._codes[code]
        return True, entry.token
