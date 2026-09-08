"""Zugangskontrolle für die Strecke Uhr -> Proxy.

Der Token ist ein geteiltes Geheimnis, keine Identität: er hält Fremde von der
/v1-Oberfläche fern und hält den ABS-API-Key serverseitig. Mehr soll er nicht.
"""

from __future__ import annotations

import base64
import hashlib
import hmac
import time
from collections import defaultdict
from dataclasses import dataclass, field


def verify_token(presented: str, tokens: tuple[str, ...]) -> bool:
    """Konstantzeitiger Vergleich gegen alle gültigen Token.

    Ohne Short-Circuit: es werden immer alle Token geprüft, damit die Laufzeit
    nicht verrät, welcher der Kandidaten getroffen wurde.
    """
    hit = False
    for token in tokens:
        hit |= hmac.compare_digest(presented, token)
    return hit


def token_from_header(header: str | None) -> str | None:
    if not header:
        return None
    scheme, _, value = header.partition(" ")
    if scheme.lower() != "bearer" or not value.strip():
        return None
    return value.strip()


# --- Vorsignierte Cover-URLs -------------------------------------------------
#
# Communications.makeImageRequest kennt kein :headers, das Cover kann den
# Bearer-Header also nicht mitschicken. Der Token als Query-Parameter würde in
# jedem Reverse-Proxy-Log landen, deshalb eine kurzlebige Signatur.


def sign_cover(book_id: str, expires_at: int, key: str) -> str:
    mac = hmac.new(key.encode(), f"{book_id}|{expires_at}".encode(), hashlib.sha256)
    return base64.urlsafe_b64encode(mac.digest()).decode().rstrip("=")


def verify_cover(book_id: str, expires_at: int, signature: str, keys: tuple[str, ...], now: float | None = None) -> bool:
    now = time.time() if now is None else now
    if expires_at < now:
        return False
    valid = False
    for key in keys:
        valid |= hmac.compare_digest(signature, sign_cover(book_id, expires_at, key))
    return valid


# --- Backoff -----------------------------------------------------------------


@dataclass
class FailureTracker:
    """Bremst Rateversuche aus, ohne einen legitimen Client auszusperren."""

    threshold: int = 5
    lockout_seconds: float = 60.0
    _failures: dict[str, list[float]] = field(default_factory=lambda: defaultdict(list))
    _locked_until: dict[str, float] = field(default_factory=dict)

    def locked(self, client: str, now: float | None = None) -> float:
        """Verbleibende Sperrzeit in Sekunden, 0 wenn offen."""
        now = time.time() if now is None else now
        until = self._locked_until.get(client, 0.0)
        return max(0.0, until - now)

    def record_failure(self, client: str, now: float | None = None) -> None:
        now = time.time() if now is None else now
        recent = [t for t in self._failures[client] if now - t < self.lockout_seconds]
        recent.append(now)
        self._failures[client] = recent
        if len(recent) >= self.threshold:
            self._locked_until[client] = now + self.lockout_seconds
            self._failures[client] = []

    def record_success(self, client: str) -> None:
        self._failures.pop(client, None)
        self._locked_until.pop(client, None)
