import pytest

from abconnect_proxy.config import ConfigError, load

MINIMAL = {"ABS_URL": "https://abs.example", "ABS_API_KEY": "k" * 20, "ABCONNECT_TOKEN": "t" * 20}


def test_loads_with_the_three_required_variables():
    config = load(MINIMAL)
    assert config.abs_url == "https://abs.example"
    assert config.tokens == ("t" * 20,)
    assert config.segment_target_seconds == 900


def test_strips_a_trailing_slash_from_the_url():
    assert load({**MINIMAL, "ABS_URL": "https://abs.example/"}).abs_url == "https://abs.example"


def test_reads_a_token_list_for_rotation():
    config = load({**MINIMAL, "ABCONNECT_TOKEN": f"{'a' * 20}, {'b' * 20}"})
    assert config.tokens == ("a" * 20, "b" * 20)
    assert config.signing_key == "a" * 20  # the first one is the current one


def test_reports_every_problem_at_once():
    with pytest.raises(ConfigError) as error:
        load({})
    assert len(error.value.problems) == 3
    assert "ABS_URL" in str(error.value)
    assert "ABS_API_KEY" in str(error.value)
    assert "ABCONNECT_TOKEN" in str(error.value)


@pytest.mark.parametrize(
    "env, expected",
    [
        ({"ABS_URL": "abs.example"}, "http://"),
        ({"ABCONNECT_TOKEN": "short"}, "16 characters"),
        ({"SEGMENT_TARGET_SECONDS": "not a number"}, "not an integer"),
        ({"SEGMENT_TARGET_SECONDS": "10"}, "minimum"),
        ({"SEGMENT_MIN_SECONDS": "1200"}, "implausible"),
    ],
)
def test_rejects_implausible_values(env, expected):
    with pytest.raises(ConfigError) as error:
        load({**MINIMAL, **env})
    assert expected in str(error.value)


def test_nothing_is_baked_in():
    """Without an environment, no default may supply a server address or a key."""
    with pytest.raises(ConfigError):
        load({})
