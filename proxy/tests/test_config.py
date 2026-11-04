import pytest

from abconnect_proxy.config import ConfigError, load

from .conftest import write_users

TOKEN = "t" * 20
ALICE = {"tokens": [TOKEN], "abs_url": "https://abs.example", "abs_api_key": "k" * 20}


@pytest.fixture
def env(tmp_path):
    """An environment whose users file holds the given users (default: alice)."""

    def _env(users=None, extra: dict | None = None):
        path = write_users(
            tmp_path / "users.toml", {"alice": ALICE} if users is None else users
        )
        env = {"USERS_FILE": str(path)}
        if extra:
            env.update(extra)
        return env

    return _env


def problems_of(env) -> list[str]:
    with pytest.raises(ConfigError) as error:
        load(env)
    return error.value.problems


class TestUsers:
    def test_loads_a_single_user(self, env):
        config = load(env())
        (user,) = config.users
        assert user.name == "alice"
        assert user.abs_url == "https://abs.example"
        assert user.tokens == (TOKEN,)
        assert user.playlist == "Garmin"
        assert config.transcode_bitrate_kbps == 64

    def test_several_users_each_keep_their_own_server_and_key(self, env):
        bob = {
            "tokens": ["b" * 20],
            "abs_url": "https://other.example",
            "abs_api_key": "x" * 20,
        }
        config = load(env({"alice": ALICE, "bob": bob}))
        assert [(u.name, u.abs_url, u.abs_api_key) for u in config.users] == [
            ("alice", "https://abs.example", "k" * 20),
            ("bob", "https://other.example", "x" * 20),
        ]

    def test_strips_a_trailing_slash_from_the_url(self, env):
        config = load(env({"alice": {**ALICE, "abs_url": "https://abs.example/"}}))
        assert config.users[0].abs_url == "https://abs.example"

    def test_reads_a_token_list_for_rotation(self, env):
        config = load(env({"alice": {**ALICE, "tokens": ["a" * 20, "b" * 20]}}))
        assert config.users[0].tokens == ("a" * 20, "b" * 20)

    def test_the_playlist_defaults_to_abs_playlist_and_can_be_overridden(self, env):
        bob = {**ALICE, "tokens": ["b" * 20], "playlist": "Bob"}
        config = load(env({"alice": ALICE, "bob": bob}, {"ABS_PLAYLIST": "Uhr"}))
        assert [u.playlist for u in config.users] == ["Uhr", "Bob"]

    def test_secrets_stay_out_of_the_repr(self, env):
        text = repr(load(env()).users[0])
        assert TOKEN not in text
        assert "k" * 20 not in text


class TestUserProblems:
    def test_reports_every_problem_at_once(self, env):
        problems = problems_of(env({"alice": {}}))
        assert len(problems) == 3
        text = "\n".join(problems)
        for expected in (
            "users.alice: abs_url",
            "users.alice: abs_api_key",
            "users.alice: tokens",
        ):
            assert expected in text

    def test_a_missing_users_file_is_reported(self, tmp_path):
        problems = problems_of({"USERS_FILE": str(tmp_path / "nope.toml")})
        assert "does not exist" in problems[0]

    def test_a_broken_users_file_is_reported(self, tmp_path):
        path = tmp_path / "users.toml"
        path.write_text("[users.alice\n", encoding="utf-8")
        assert "not valid TOML" in problems_of({"USERS_FILE": str(path)})[0]

    def test_a_file_without_users_is_reported(self, tmp_path):
        path = tmp_path / "users.toml"
        path.write_text("", encoding="utf-8")
        assert "no users defined" in problems_of({"USERS_FILE": str(path)})[0]

    @pytest.mark.parametrize(
        "entry, expected",
        [
            ({"abs_url": "abs.example"}, "http://"),
            ({"tokens": ["short"]}, "16 characters"),
            ({"tokens": TOKEN}, "tokens missing"),  # a plain string, not a list
            ({"tokens": []}, "tokens missing"),
            ({"playlst": "Garmin"}, "unknown keys playlst"),
            ({"playlist": ""}, "playlist must not be empty"),
        ],
    )
    def test_rejects_implausible_user_entries(self, env, entry, expected):
        assert expected in "\n".join(problems_of(env({"alice": {**ALICE, **entry}})))

    def test_a_user_name_must_be_a_safe_path_segment(self, env):
        assert "name may only contain" in problems_of(env({"../evil": ALICE}))[0]

    def test_a_token_belongs_to_one_user_only(self, env):
        problems = problems_of(
            env({"alice": ALICE, "bob": {**ALICE, "abs_api_key": "x" * 20}})
        )
        assert problems == ["users.bob: shares a token with users.alice"]
        assert TOKEN not in problems[0]


@pytest.mark.parametrize(
    "extra, expected",
    [
        ({"TRANSCODE_BITRATE_KBPS": "not a number"}, "not an integer"),
        ({"TRANSCODE_BITRATE_KBPS": "8"}, "minimum"),
        ({"PLAYLIST_POLL_SECONDS": "1"}, "minimum"),
    ],
)
def test_rejects_implausible_values(env, extra, expected):
    assert expected in "\n".join(problems_of(env(extra=extra)))


def test_nothing_is_baked_in():
    """Without an environment, no default may supply a user, server or key."""
    assert any("USERS_FILE" in problem for problem in problems_of({}))


def test_m4b_chapters_are_encoded_at_64_kbps_unless_told_otherwise(env):
    config = load(env())
    assert config.transcode_bitrate_kbps == 64
    assert (
        load(env(extra={"TRANSCODE_BITRATE_KBPS": "96"})).transcode_bitrate_kbps == 96
    )
