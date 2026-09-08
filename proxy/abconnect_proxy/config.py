"""Laufzeitkonfiguration.

Im Image steht nichts: Adresse und Schlüssel kommen ausschließlich aus der
Umgebung. Fehlt etwas, startet der Prozess nicht — und zwar mit *allen*
Beanstandungen auf einmal, damit ein Fehlstart nicht zur Salamitaktik wird.
"""

from __future__ import annotations

import os
from dataclasses import dataclass
from pathlib import Path

DEFAULTS = {
    "CACHE_DIR": "/var/cache/abconnect",
    "WORK_DIR": "/var/tmp/abconnect",
    "CACHE_MAX_BYTES": str(200 * 1024**3),
    "RELEASE_TTL_DAYS": "30",
    "SEGMENT_TARGET_SECONDS": "900",
    "SEGMENT_MIN_SECONDS": "180",
    "SEGMENT_MAX_SECONDS": "1500",
    "COVER_URL_TTL_SECONDS": "21600",
    "HTTP_TIMEOUT_SECONDS": "60",
    "LOG_LEVEL": "INFO",
}


class ConfigError(Exception):
    """Sammelt alle Konfigurationsfehler, statt beim ersten abzubrechen."""

    def __init__(self, problems: list[str]) -> None:
        self.problems = problems
        super().__init__("Ungültige Konfiguration:\n  - " + "\n  - ".join(problems))


@dataclass(frozen=True)
class Config:
    abs_url: str
    abs_api_key: str
    tokens: tuple[str, ...]
    cache_dir: Path
    work_dir: Path
    cache_max_bytes: int
    release_ttl_days: int
    segment_target_seconds: int
    segment_min_seconds: int
    segment_max_seconds: int
    cover_url_ttl_seconds: int
    http_timeout_seconds: float
    log_level: str

    @property
    def signing_key(self) -> str:
        """Schlüssel für vorsignierte Cover-URLs: der erste (aktuelle) Token."""
        return self.tokens[0]


def _int(env: dict[str, str], key: str, problems: list[str], minimum: int = 1) -> int:
    raw = env.get(key) or DEFAULTS[key]
    try:
        value = int(raw)
    except ValueError:
        problems.append(f"{key}: '{raw}' ist keine ganze Zahl")
        return minimum
    if value < minimum:
        problems.append(f"{key}: {value} liegt unter dem Minimum {minimum}")
        return minimum
    return value


def load(env: dict[str, str] | None = None) -> Config:
    env = dict(os.environ if env is None else env)
    problems: list[str] = []

    abs_url = (env.get("ABS_URL") or "").strip().rstrip("/")
    if not abs_url:
        problems.append("ABS_URL fehlt (Basis-URL der Audiobookshelf-Instanz)")
    elif not abs_url.startswith(("http://", "https://")):
        problems.append(f"ABS_URL: '{abs_url}' braucht http:// oder https://")

    abs_api_key = (env.get("ABS_API_KEY") or "").strip()
    if not abs_api_key:
        problems.append("ABS_API_KEY fehlt (als Podman-Secret einhängen)")

    # Komma-Liste: der neue Token kann gesetzt werden, bevor der alte aus den
    # Uhreneinstellungen verschwunden ist.
    tokens = tuple(t.strip() for t in (env.get("ABCONNECT_TOKEN") or "").split(",") if t.strip())
    if not tokens:
        problems.append("ABCONNECT_TOKEN fehlt (Token für die Uhr)")
    elif any(len(t) < 16 for t in tokens):
        problems.append("ABCONNECT_TOKEN: jeder Token braucht mindestens 16 Zeichen")

    cache_max = _int(env, "CACHE_MAX_BYTES", problems, minimum=1024**3)
    release_ttl = _int(env, "RELEASE_TTL_DAYS", problems, minimum=0)
    target = _int(env, "SEGMENT_TARGET_SECONDS", problems, minimum=60)
    seg_min = _int(env, "SEGMENT_MIN_SECONDS", problems, minimum=1)
    seg_max = _int(env, "SEGMENT_MAX_SECONDS", problems, minimum=60)
    cover_ttl = _int(env, "COVER_URL_TTL_SECONDS", problems, minimum=60)
    timeout = _int(env, "HTTP_TIMEOUT_SECONDS", problems, minimum=5)

    if not seg_min <= target <= seg_max:
        problems.append(
            f"Segmentgrenzen unplausibel: MIN={seg_min} <= TARGET={target} <= MAX={seg_max} gilt nicht"
        )

    if problems:
        raise ConfigError(problems)

    return Config(
        abs_url=abs_url,
        abs_api_key=abs_api_key,
        tokens=tokens,
        cache_dir=Path(env.get("CACHE_DIR") or DEFAULTS["CACHE_DIR"]),
        work_dir=Path(env.get("WORK_DIR") or DEFAULTS["WORK_DIR"]),
        cache_max_bytes=cache_max,
        release_ttl_days=release_ttl,
        segment_target_seconds=target,
        segment_min_seconds=seg_min,
        segment_max_seconds=seg_max,
        cover_url_ttl_seconds=cover_ttl,
        http_timeout_seconds=float(timeout),
        log_level=(env.get("LOG_LEVEL") or DEFAULTS["LOG_LEVEL"]).upper(),
    )
