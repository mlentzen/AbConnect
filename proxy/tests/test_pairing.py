import pytest

from abconnect_proxy.pairing import ALPHABET, CODE_LENGTH, PairingFull, PairingRegistry

from .test_api import BOB_TOKEN, TOKEN, build_client, load_config


@pytest.fixture
def config(tmp_path):
    return load_config(tmp_path)


class TestRegistry:
    def test_codes_use_the_readable_alphabet(self):
        code = PairingRegistry().start()
        assert len(code) == CODE_LENGTH
        assert set(code) <= set(ALPHABET)

    def test_token_is_handed_out_once(self):
        registry = PairingRegistry()
        code = registry.start(now=0)
        assert registry.poll(code, now=1) == (True, None)
        assert registry.complete(code, "secret", now=2)
        assert registry.poll(code, now=3) == (True, "secret")
        assert registry.poll(code, now=4) == (False, None)

    def test_codes_expire(self):
        registry = PairingRegistry(ttl=10)
        code = registry.start(now=0)
        assert not registry.complete(code, "secret", now=11)
        assert registry.poll(code, now=11) == (False, None)

    def test_code_survives_phone_typing(self):
        registry = PairingRegistry()
        code = registry.start(now=0)
        sloppy = f" {code[:3].lower()} {code[3:]} "
        assert registry.complete(sloppy, "secret", now=1)

    def test_open_codes_are_bounded(self):
        registry = PairingRegistry(max_pending=2)
        registry.start(now=0)
        registry.start(now=0)
        with pytest.raises(PairingFull):
            registry.start(now=0)


class TestRoutes:
    def test_full_pairing(self, config):
        with build_client(config) as client:
            started = client.post("/pair/start")
            assert started.status_code == 200
            code = started.json()["code"]

            assert client.get(f"/pair/{code}").status_code == 202

            form = client.post("/pair", data={"code": code.lower(), "token": BOB_TOKEN})
            assert form.status_code == 200
            assert "Paired" in form.text

            delivered = client.get(f"/pair/{code}")
            assert delivered.status_code == 200
            assert delivered.json() == {"token": BOB_TOKEN}
            assert client.get(f"/pair/{code}").status_code == 404

    def test_form_is_served(self, config):
        with build_client(config) as client:
            page = client.get("/pair")
            assert page.status_code == 200
            assert "<form" in page.text

    def test_invalid_token_does_not_pair(self, config):
        with build_client(config) as client:
            code = client.post("/pair/start").json()["code"]
            form = client.post("/pair", data={"code": code, "token": "not-a-real-token-at-all"})
            assert form.status_code == 401
            assert client.get(f"/pair/{code}").status_code == 202

    def test_unknown_code_is_refused(self, config):
        with build_client(config) as client:
            form = client.post("/pair", data={"code": "ZZZZZZ", "token": TOKEN})
            assert form.status_code == 404
            assert client.get("/pair/ZZZZZZ").status_code == 404

    def test_guessing_codes_locks_out(self, config):
        with build_client(config) as client:
            for _ in range(5):
                client.get("/pair/ZZZZZZ")
            assert client.get("/pair/ZZZZZZ").status_code == 429
            assert client.post("/pair/start").status_code == 429

    def test_pair_failures_do_not_lock_out_the_api(self, config):
        with build_client(config) as client:
            for _ in range(6):
                client.get("/pair/ZZZZZZ")
            response = client.get("/v1/playlist", headers={"Authorization": f"Bearer {TOKEN}"})
            assert response.status_code != 429

    def test_pairing_output_is_escaped(self, config):
        with build_client(config) as client:
            form = client.post("/pair", data={"code": "<script>", "token": "x"})
            assert "<script>" not in form.text
