"""Runtime configuration.

Nothing is baked into the image: address and keys come exclusively from the
environment. If something is missing, the process does not start — and it
reports *all* complaints at once so a failed start does not turn into salami
tactics.
"""

from __future__ import annotations

import os
from dataclasses import dataclass
from pathlib import Path

DEFAULTS = {
    "ABS_PLAYLIST": "Garmin",
    "PLAYLIST_POLL_SECONDS": "600",
    "CACHE_DIR": "/var/cache/abconnect",
    "WORK_DIR": "/var/tmp/abconnect",
    "CACHE_MAX_BYTES": str(200 * 1024**3),
    "RELEASE_TTL_DAYS": "30",
    "SEGMENT_TARGET_SECONDS": "900",
    "SEGMENT_MIN_SECONDS": "180",
    "SEGMENT_MAX_SECONDS": "1500",
    "COVER_URL_TTL_SECONDS": "21600",
    "TRANSCODE_MODE": "auto",
    "TRANSCODE_TARGET": "m4a",
    "TRANSCODE_BITRATE_KBPS": "64",
    "HTTP_TIMEOUT_SECONDS": "60",
    "LOG_LEVEL": "INFO",
}


class ConfigError(Exception):
    """Collects all configuration errors instead of aborting on the first."""

    def __init__(self, problems: list[str]) -> None:
        self.problems = problems
        super().__init__("Invalid configuration:\n  - " + "\n  - ".join(problems))


@dataclass(frozen=True)
class Config:
    abs_url: str
    abs_api_key: str
    abs_playlist: str
    tokens: tuple[str, ...]
    playlist_poll_seconds: int
    cache_dir: Path
    work_dir: Path
    cache_max_bytes: int
    release_ttl_days: int
    segment_target_seconds: int
    segment_min_seconds: int
    segment_max_seconds: int
    cover_url_ttl_seconds: int
    transcode_mode: str
    transcode_target: str
    transcode_bitrate_kbps: int
    http_timeout_seconds: float
    log_level: str

    @property
    def signing_key(self) -> str:
        """Key for pre-signed cover URLs: the first (current) token."""
        return self.tokens[0]


def _int(env: dict[str, str], key: str, problems: list[str], minimum: int = 1) -> int:
    raw = env.get(key) or DEFAULTS[key]
    try:
        value = int(raw)
    except ValueError:
        problems.append(f"{key}: '{raw}' is not an integer")
        return minimum
    if value < minimum:
        problems.append(f"{key}: {value} is below the minimum {minimum}")
        return minimum
    return value


def load(env: dict[str, str] | None = None) -> Config:
    env = dict(os.environ if env is None else env)
    problems: list[str] = []

    abs_url = (env.get("ABS_URL") or "").strip().rstrip("/")
    if not abs_url:
        problems.append("ABS_URL missing (base URL of the Audiobookshelf instance)")
    elif not abs_url.startswith(("http://", "https://")):
        problems.append(f"ABS_URL: '{abs_url}' needs http:// or https://")

    abs_api_key = (env.get("ABS_API_KEY") or "").strip()
    if not abs_api_key:
        problems.append("ABS_API_KEY missing (mount as a Podman secret)")

    # The playlist is the target: whatever is in it goes onto the watch.
    abs_playlist = (env.get("ABS_PLAYLIST") or DEFAULTS["ABS_PLAYLIST"]).strip()
    if not abs_playlist:
        problems.append("ABS_PLAYLIST must not be empty")

    # Comma list: the new token can be set before the old one has disappeared
    # from the watch settings.
    tokens = tuple(t.strip() for t in (env.get("ABCONNECT_TOKEN") or "").split(",") if t.strip())
    if not tokens:
        problems.append("ABCONNECT_TOKEN missing (token for the watch)")
    elif any(len(t) < 16 for t in tokens):
        problems.append("ABCONNECT_TOKEN: every token needs at least 16 characters")

    cache_max = _int(env, "CACHE_MAX_BYTES", problems, minimum=1024**3)
    release_ttl = _int(env, "RELEASE_TTL_DAYS", problems, minimum=0)
    target = _int(env, "SEGMENT_TARGET_SECONDS", problems, minimum=60)
    seg_min = _int(env, "SEGMENT_MIN_SECONDS", problems, minimum=1)
    seg_max = _int(env, "SEGMENT_MAX_SECONDS", problems, minimum=60)
    cover_ttl = _int(env, "COVER_URL_TTL_SECONDS", problems, minimum=60)
    poll = _int(env, "PLAYLIST_POLL_SECONDS", problems, minimum=60)
    timeout = _int(env, "HTTP_TIMEOUT_SECONDS", problems, minimum=5)
    bitrate = _int(env, "TRANSCODE_BITRATE_KBPS", problems, minimum=32)

    # "auto" re-encodes only what `media.conforms()` rejects. "always" is the
    # switch for testing a format hypothesis on the watch without a code change,
    # "never" the way back to pure stream copy.
    transcode_mode = (env.get("TRANSCODE_MODE") or DEFAULTS["TRANSCODE_MODE"]).strip().lower()
    if transcode_mode not in ("auto", "always", "never"):
        problems.append(f"TRANSCODE_MODE: '{transcode_mode}' is not auto, always or never")

    # m4a keeps the container the watch already receives; mp3 is the fallback
    # the one working reference implementation runs in production.
    transcode_target = (env.get("TRANSCODE_TARGET") or DEFAULTS["TRANSCODE_TARGET"]).strip().lower()
    if transcode_target not in ("m4a", "mp3"):
        problems.append(f"TRANSCODE_TARGET: '{transcode_target}' is not m4a or mp3")

    if not seg_min <= target <= seg_max:
        problems.append(
            f"Segment bounds implausible: MIN={seg_min} <= TARGET={target} <= MAX={seg_max} does not hold"
        )

    if problems:
        raise ConfigError(problems)

    return Config(
        abs_url=abs_url,
        abs_api_key=abs_api_key,
        abs_playlist=abs_playlist,
        tokens=tokens,
        playlist_poll_seconds=poll,
        cache_dir=Path(env.get("CACHE_DIR") or DEFAULTS["CACHE_DIR"]),
        work_dir=Path(env.get("WORK_DIR") or DEFAULTS["WORK_DIR"]),
        cache_max_bytes=cache_max,
        release_ttl_days=release_ttl,
        segment_target_seconds=target,
        segment_min_seconds=seg_min,
        segment_max_seconds=seg_max,
        cover_url_ttl_seconds=cover_ttl,
        transcode_mode=transcode_mode,
        transcode_target=transcode_target,
        transcode_bitrate_kbps=bitrate,
        http_timeout_seconds=float(timeout),
        log_level=(env.get("LOG_LEVEL") or DEFAULTS["LOG_LEVEL"]).upper(),
    )
