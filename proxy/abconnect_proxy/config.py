"""Runtime configuration.

Nothing is baked into the image: users and keys come exclusively from the
users file, everything else from the environment. If something is missing, the
process does not start — and it reports *all* complaints at once so a failed
start does not turn into salami tactics.
"""

from __future__ import annotations

import os
import re
import tomllib
from dataclasses import dataclass, field
from pathlib import Path

DEFAULTS = {
    "USERS_FILE": "/run/secrets/users.toml",
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
    "TRANSCODE_TARGET": "mp3",
    "TRANSCODE_BITRATE_KBPS": "64",
    "HTTP_TIMEOUT_SECONDS": "60",
    "LOG_LEVEL": "INFO",
}

# The name becomes a directory below the cache, so it must be a safe path segment.
USER_NAME = re.compile(r"^[A-Za-z0-9_-]{1,64}$")
USER_KEYS = frozenset({"tokens", "abs_url", "abs_api_key", "playlist"})


class ConfigError(Exception):
    """Collects all configuration errors instead of aborting on the first."""

    def __init__(self, problems: list[str]) -> None:
        self.problems = problems
        super().__init__("Invalid configuration:\n  - " + "\n  - ".join(problems))


@dataclass(frozen=True)
class UserConfig:
    """One person behind the proxy: their token(s), their ABS, their playlist."""

    name: str
    tokens: tuple[str, ...] = field(repr=False)
    abs_url: str
    abs_api_key: str = field(repr=False)
    playlist: str

    @property
    def signing_key(self) -> str:
        """Key for pre-signed cover URLs: the first (current) token."""
        return self.tokens[0]


@dataclass(frozen=True)
class Config:
    users: tuple[UserConfig, ...]
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


def _users(text: str, default_playlist: str, problems: list[str]) -> tuple[UserConfig, ...]:
    """Parses the users file. Problems name the user, never a token or key."""
    try:
        data = tomllib.loads(text)
    except tomllib.TOMLDecodeError as error:
        problems.append(f"USERS_FILE: not valid TOML ({error})")
        return ()

    unknown = sorted(set(data) - {"users"})
    if unknown:
        problems.append(f"USERS_FILE: unknown top-level keys {', '.join(unknown)}")
    table = data.get("users")
    if not isinstance(table, dict) or not table:
        problems.append("USERS_FILE: no users defined (expected [users.<name>] tables)")
        return ()

    users: list[UserConfig] = []
    # Token -> user: a token has to identify exactly one person.
    owners: dict[str, str] = {}
    for name, entry in table.items():
        where = f"users.{name}"
        if not USER_NAME.match(name):
            problems.append(f"{where}: name may only contain letters, digits, _ and - (at most 64)")
        if not isinstance(entry, dict):
            problems.append(f"{where}: must be a table")
            continue
        unknown = sorted(set(entry) - USER_KEYS)
        if unknown:
            problems.append(f"{where}: unknown keys {', '.join(unknown)}")

        abs_url = entry.get("abs_url")
        abs_url = abs_url.strip().rstrip("/") if isinstance(abs_url, str) else ""
        if not abs_url:
            problems.append(f"{where}: abs_url missing (base URL of the Audiobookshelf instance)")
        elif not abs_url.startswith(("http://", "https://")):
            problems.append(f"{where}: abs_url '{abs_url}' needs http:// or https://")

        abs_api_key = entry.get("abs_api_key")
        abs_api_key = abs_api_key.strip() if isinstance(abs_api_key, str) else ""
        if not abs_api_key:
            problems.append(f"{where}: abs_api_key missing")

        # A list, so the new token can be set before the old one has
        # disappeared from the watch settings.
        raw_tokens = entry.get("tokens")
        if not isinstance(raw_tokens, list) or not all(isinstance(t, str) for t in raw_tokens):
            raw_tokens = []
        tokens = tuple(t.strip() for t in raw_tokens if t.strip())
        if not tokens:
            problems.append(f"{where}: tokens missing (a list with at least one token for the watch)")
        elif any(len(t) < 16 for t in tokens):
            problems.append(f"{where}: every token needs at least 16 characters")
        shared = sorted({owners.setdefault(t, name) for t in tokens} - {name})
        for other in shared:
            problems.append(f"{where}: shares a token with users.{other}")

        playlist = entry.get("playlist", default_playlist)
        playlist = playlist.strip() if isinstance(playlist, str) else ""
        if not playlist:
            problems.append(f"{where}: playlist must not be empty")

        users.append(UserConfig(name, tokens, abs_url, abs_api_key, playlist))
    return tuple(users)


def _read_users(path: Path, default_playlist: str, problems: list[str]) -> tuple[UserConfig, ...]:
    try:
        text = path.read_text(encoding="utf-8")
    except FileNotFoundError:
        problems.append(f"USERS_FILE: {path} does not exist (mount the users file as a Podman secret)")
        return ()
    except OSError as error:
        problems.append(f"USERS_FILE: {path} is unreadable ({error.strerror})")
        return ()
    return _users(text, default_playlist, problems)


def load(env: dict[str, str] | None = None) -> Config:
    env = dict(os.environ if env is None else env)
    problems: list[str] = []

    # The playlist is the target: whatever is in it goes onto the watch. This
    # one is the default for every user who does not name their own.
    default_playlist = (env.get("ABS_PLAYLIST") or DEFAULTS["ABS_PLAYLIST"]).strip()
    if not default_playlist:
        problems.append("ABS_PLAYLIST must not be empty")

    users = _read_users(Path(env.get("USERS_FILE") or DEFAULTS["USERS_FILE"]), default_playlist, problems)

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

    # mp3 is what the one working reference implementation runs in production —
    # unlike m4a/AAC it is proven to actually start on the watch. m4a stays
    # selectable for a source that already conforms and would rather keep its
    # container.
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
        users=users,
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
