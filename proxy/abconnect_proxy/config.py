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
    "CACHE_MAX_BYTES": str(20 * 1024**3),
    "RELEASE_TTL_DAYS": "30",
    "TRANSCODE_BITRATE_KBPS": "64",
    "HTTP_TIMEOUT_SECONDS": "60",
    "LOG_LEVEL": "INFO",
}

# The name becomes a directory below the cache, so it must be a safe path segment.
USER_NAME = re.compile(r"^[A-Za-z0-9_-]{1,64}$")
USER_KEYS = frozenset({"tokens", "abs_url", "abs_api_key", "playlist"})


class ConfigError(Exception):
    """All configuration errors found in one load, instead of only the first.

    Attributes:
        problems: One message per problem. Messages name the user or the
            setting, never a token or an API key.
    """

    def __init__(self, problems: list[str]) -> None:
        """Store every problem and format them as the exception message.

        Args:
            problems: Messages collected while reading the environment and
                the users file.
        """
        self.problems = problems
        super().__init__("Invalid configuration:\n  - " + "\n  - ".join(problems))


@dataclass(frozen=True)
class UserConfig:
    """One person: how their watch authenticates, and which Audiobookshelf is theirs.

    Attributes:
        name: Also the cache directory, so it has to be a safe path segment.
        tokens: Bearer tokens the watch may send. More than one is allowed
            so a new token can be installed before the old one is removed
            from the device.
        abs_url: That person's Audiobookshelf server.
        abs_api_key: How the proxy calls that server.
        playlist: Playlist name whose books are prepared for their watch.
    """

    name: str
    tokens: tuple[str, ...] = field(repr=False)
    abs_url: str
    abs_api_key: str = field(repr=False)
    playlist: str


@dataclass(frozen=True)
class Config:
    """Settings for the whole process.

    Each user still has their own server, key, tokens and playlist. The
    fields below apply to every user.

    Attributes:
        users: One entry per person.
        playlist_poll_seconds: How often each playlist is re-read.
        cache_dir: Where the segments are stored.
        work_dir: Where a source file sits while it is being cut.
        cache_max_bytes: Disk budget shared by every user.
        release_ttl_days: How long a book stays on disk after it leaves its
            playlist.
        transcode_bitrate_kbps: Bitrate per channel of every segment encoded
            to mp3. A stereo segment uses twice this.
        http_timeout_seconds: Request timeout for Audiobookshelf calls.
        log_level: Logging level name, such as "INFO".
    """

    users: tuple[UserConfig, ...]
    playlist_poll_seconds: int
    cache_dir: Path
    work_dir: Path
    cache_max_bytes: int
    release_ttl_days: int
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


def _users(
    text: str, default_playlist: str, problems: list[str]
) -> tuple[UserConfig, ...]:
    """Parse the users file.

    Problems name the user, never a token or a key.

    Args:
        text: Contents of the users file.
        default_playlist: Playlist name for a user who does not set one.
        problems: Messages are appended here. Parsing continues after a
            problem so every complaint is reported together.

    Returns:
        The users that could be read. Empty when the file has no user table.
    """
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
            problems.append(
                f"{where}: name may only contain letters, digits, _ and - (at most 64)"
            )
        if not isinstance(entry, dict):
            problems.append(f"{where}: must be a table")
            continue
        unknown = sorted(set(entry) - USER_KEYS)
        if unknown:
            problems.append(f"{where}: unknown keys {', '.join(unknown)}")

        abs_url = entry.get("abs_url")
        abs_url = abs_url.strip().rstrip("/") if isinstance(abs_url, str) else ""
        if not abs_url:
            problems.append(
                f"{where}: abs_url missing (base URL of the Audiobookshelf instance)"
            )
        elif not abs_url.startswith(("http://", "https://")):
            problems.append(f"{where}: abs_url '{abs_url}' needs http:// or https://")

        abs_api_key = entry.get("abs_api_key")
        abs_api_key = abs_api_key.strip() if isinstance(abs_api_key, str) else ""
        if not abs_api_key:
            problems.append(f"{where}: abs_api_key missing")

        # A list, so the new token can be set before the old one has
        # disappeared from the watch settings.
        raw_tokens = entry.get("tokens")
        if not isinstance(raw_tokens, list) or not all(
            isinstance(t, str) for t in raw_tokens
        ):
            raw_tokens = []
        tokens = tuple(t.strip() for t in raw_tokens if t.strip())
        if not tokens:
            problems.append(
                f"{where}: tokens missing (a list with at least one token for the watch)"
            )
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


def _read_users(
    path: Path, default_playlist: str, problems: list[str]
) -> tuple[UserConfig, ...]:
    try:
        text = path.read_text(encoding="utf-8")
    except FileNotFoundError:
        problems.append(
            f"USERS_FILE: {path} does not exist (mount the users file as a Podman secret)"
        )
        return ()
    except OSError as error:
        problems.append(f"USERS_FILE: {path} is unreadable ({error.strerror})")
        return ()
    return _users(text, default_playlist, problems)


def load(env: dict[str, str] | None = None) -> Config:
    """Read configuration.

    No user, server or key is filled in when the environment does not
    provide one.

    Args:
        env: Stands in for the process environment. Tests pass it. Omit it
            in production and the real environment is read.

    Returns:
        The process configuration.

    Raises:
        ConfigError: One or more settings are missing or implausible. Every
            problem found is on the exception.
    """
    env = dict(os.environ if env is None else env)
    problems: list[str] = []

    # The playlist is the target: whatever is in it goes onto the watch. This
    # one is the default for every user who does not name their own.
    default_playlist = (env.get("ABS_PLAYLIST") or DEFAULTS["ABS_PLAYLIST"]).strip()
    if not default_playlist:
        problems.append("ABS_PLAYLIST must not be empty")

    users = _read_users(
        Path(env.get("USERS_FILE") or DEFAULTS["USERS_FILE"]),
        default_playlist,
        problems,
    )

    cache_max = _int(env, "CACHE_MAX_BYTES", problems, minimum=1024**3)
    release_ttl = _int(env, "RELEASE_TTL_DAYS", problems, minimum=0)
    poll = _int(env, "PLAYLIST_POLL_SECONDS", problems, minimum=60)
    timeout = _int(env, "HTTP_TIMEOUT_SECONDS", problems, minimum=5)
    bitrate = _int(env, "TRANSCODE_BITRATE_KBPS", problems, minimum=32)

    if problems:
        raise ConfigError(problems)

    return Config(
        users=users,
        playlist_poll_seconds=poll,
        cache_dir=Path(env.get("CACHE_DIR") or DEFAULTS["CACHE_DIR"]),
        work_dir=Path(env.get("WORK_DIR") or DEFAULTS["WORK_DIR"]),
        cache_max_bytes=cache_max,
        release_ttl_days=release_ttl,
        transcode_bitrate_kbps=bitrate,
        http_timeout_seconds=float(timeout),
        log_level=(env.get("LOG_LEVEL") or DEFAULTS["LOG_LEVEL"]).upper(),
    )
