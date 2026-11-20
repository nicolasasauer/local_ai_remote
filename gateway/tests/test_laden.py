"""Ladeoptionen und Downloads.

Was hier geprueft wird, sind die Stellen, an denen die App ueber den Speicher
des Desktops bestimmt: wie viel Kontext ein Modell bekommt, wie lange es
bleibt, ob es neu aus dem Netz kommt. Jede davon soll entweder genau das tun,
was angefordert wurde, oder mit Grund ablehnen.
"""

from __future__ import annotations

import asyncio
import dataclasses
import json
import subprocess
from types import SimpleNamespace

import httpx
import pytest
from fastapi.testclient import TestClient

from gateway import main as gw
from gateway.backends import lmstudio as lms_modul
from gateway.backends.base import BackendError, check_model_name
from gateway.backends.lmstudio import LmStudioBackend
from gateway.backends.ollama import OllamaBackend
from gateway.pulls import PullBusy, PullManager
from gateway.schema import (
    BackendId,
    ChatMessage,
    ChatRequest,
    Fact,
    GpuMode,
    LoadOptions,
    ModelEntry,
    ModelState,
    PullState,
)
from gateway.tests.test_gateway import FakeBackend, TOKEN, auth, sse


def ndjson(*chunks: dict) -> bytes:
    return b"".join(json.dumps(c).encode() + b"\n" for c in chunks)


# ---------------------------------------------------------------------------
# Eingaben
# ---------------------------------------------------------------------------


class TestModellname:
    @pytest.mark.parametrize(
        "name", ["qwen3:8b", "hf.co/bartowski/Qwen3-8B-GGUF:Q4_K_M", "qwen/qwen3-coder-30b"]
    )
    def test_echte_namen_gehen_durch(self, name):
        assert check_model_name(name) == name

    @pytest.mark.parametrize("name", ["--all", "-y", "", "a b", "../../etc", "x;rm -rf"])
    def test_schalter_und_unsinn_werden_abgelehnt(self, name):
        with pytest.raises(BackendError) as exc:
            check_model_name(name)
        assert exc.value.status_code == 400


class TestLadeoptionen:
    def test_haltedauer_hat_grenzen(self):
        LoadOptions(keep_alive=-1)
        LoadOptions(keep_alive=0)
        LoadOptions(keep_alive=3600)
        with pytest.raises(ValueError):
            LoadOptions(keep_alive=-5)
        with pytest.raises(ValueError):
            LoadOptions(keep_alive=10**9)

    def test_kontext_hat_untergrenze(self):
        with pytest.raises(ValueError):
            LoadOptions(context_length=10)


# ---------------------------------------------------------------------------
# Ollama
# ---------------------------------------------------------------------------


def _ollama(gesendet: list) -> OllamaBackend:
    def handler(request: httpx.Request) -> httpx.Response:
        if request.url.path == "/api/show":
            return httpx.Response(200, json={"capabilities": ["completion"]})
        gesendet.append((request.url.path, json.loads(request.content)))
        if request.url.path == "/api/chat":
            return httpx.Response(
                200,
                content=ndjson(
                    {"message": {"content": "ok"}},
                    {"done": True, "prompt_eval_count": 3, "eval_count": 1},
                ),
            )
        return httpx.Response(200, json={"done": True})

    client = httpx.AsyncClient(transport=httpx.MockTransport(handler))
    return OllamaBackend("http://ollama", client)


class TestOllamaLaden:
    def test_chat_reicht_ladeoptionen_durch(self):
        gesendet: list = []
        backend = _ollama(gesendet)
        req = ChatRequest(
            backend=BackendId.ollama,
            model="m",
            messages=[ChatMessage(role="user", content="hi")],
            temperature=0.3,
            load=LoadOptions(context_length=16384, keep_alive=1800, gpu=GpuMode.off),
        )

        async def lauf():
            return [e async for e in backend.stream_chat(req)]

        asyncio.run(lauf())
        pfad, payload = gesendet[-1]
        assert pfad == "/api/chat"
        assert payload["options"] == {"temperature": 0.3, "num_ctx": 16384, "num_gpu": 0}
        assert payload["keep_alive"] == 1800

    def test_ohne_ladeoptionen_bleibt_die_anfrage_wie_bisher(self):
        gesendet: list = []
        backend = _ollama(gesendet)
        req = ChatRequest(
            backend=BackendId.ollama,
            model="m",
            messages=[ChatMessage(role="user", content="hi")],
        )

        async def lauf():
            return [e async for e in backend.stream_chat(req)]

        asyncio.run(lauf())
        _, payload = gesendet[-1]
        assert "options" not in payload
        assert "keep_alive" not in payload

    def test_jetzt_laden_schickt_generate_ohne_prompt(self):
        gesendet: list = []
        backend = _ollama(gesendet)
        asyncio.run(
            backend.load("m", LoadOptions(context_length=8192, gpu=GpuMode.max, keep_alive=-1))
        )
        pfad, payload = gesendet[-1]
        assert pfad == "/api/generate"
        assert "prompt" not in payload
        assert payload == {
            "model": "m",
            "options": {"num_ctx": 8192, "num_gpu": 999},
            "keep_alive": -1,
        }


# ---------------------------------------------------------------------------
# LM Studio
# ---------------------------------------------------------------------------


class TestLmStudioLaden:
    def _backend(self, geladen: bool) -> LmStudioBackend:
        backend = LmStudioBackend("http://lms", httpx.AsyncClient())

        async def list_models():
            return [
                ModelEntry(
                    id="qwen/q",
                    label="q",
                    backend=BackendId.lmstudio,
                    state=ModelState.loaded if geladen else ModelState.not_loaded,
                )
            ]

        backend.list_models = list_models  # type: ignore[method-assign]
        return backend

    def _cli(self, monkeypatch) -> list[list[str]]:
        aufrufe: list[list[str]] = []

        def run(args, **_):
            aufrufe.append(args)
            return SimpleNamespace(returncode=0, stdout="", stderr="")

        monkeypatch.setattr(lms_modul.shutil, "which", lambda _: "/usr/bin/lms")
        monkeypatch.setattr(lms_modul.subprocess, "run", run)
        return aufrufe

    def test_chat_lehnt_kontext_und_gpu_ab(self):
        backend = self._backend(geladen=True)
        for opts in (LoadOptions(context_length=8192), LoadOptions(gpu=GpuMode.max)):
            with pytest.raises(BackendError) as exc:
                backend.check_chat_load(opts)
            assert exc.value.status_code == 400
        backend.check_chat_load(LoadOptions(keep_alive=600))

    def test_laden_baut_den_cli_aufruf(self, monkeypatch):
        aufrufe = self._cli(monkeypatch)
        backend = self._backend(geladen=False)
        asyncio.run(
            backend.load("qwen/q", LoadOptions(context_length=32768, gpu=GpuMode.max, keep_alive=900))
        )
        assert aufrufe == [[
            "/usr/bin/lms", "load", "qwen/q", "--yes",
            "--context-length", "32768", "--gpu", "max", "--ttl", "900",
        ]]

    def test_geladenes_modell_wird_vorher_entladen(self, monkeypatch):
        # Sonst legt `lms load` eine zweite Instanz daneben.
        aufrufe = self._cli(monkeypatch)
        backend = self._backend(geladen=True)
        asyncio.run(backend.load("qwen/q", LoadOptions(keep_alive=-1)))
        assert [a[1] for a in aufrufe] == ["unload", "load"]
        assert "--ttl" not in aufrufe[-1]

    def test_schalter_als_modellname_erreicht_die_cli_nie(self, monkeypatch):
        aufrufe = self._cli(monkeypatch)
        backend = self._backend(geladen=False)
        with pytest.raises(BackendError):
            asyncio.run(backend.set_keep_alive("--all", pin=False))
        with pytest.raises(BackendError):
            asyncio.run(backend.load("--all", LoadOptions()))
        assert aufrufe == []

    def test_cli_fehler_kommt_mit_grund(self, monkeypatch):
        monkeypatch.setattr(lms_modul.shutil, "which", lambda _: "/usr/bin/lms")
        monkeypatch.setattr(
            lms_modul.subprocess,
            "run",
            lambda *a, **k: SimpleNamespace(returncode=1, stdout="", stderr="out of memory"),
        )
        with pytest.raises(BackendError, match="out of memory"):
            asyncio.run(self._backend(geladen=False).load("qwen/q", LoadOptions()))


# ---------------------------------------------------------------------------
# Downloads
# ---------------------------------------------------------------------------


def _pull_von(*zeilen: dict, pause: float = 0.0):
    async def pull(model: str):
        for z in zeilen:
            if pause:
                await asyncio.sleep(pause)
            yield z

    return pull


class TestPullManager:
    def test_fortschritt_summiert_die_schichten(self):
        async def lauf():
            m = PullManager()
            m.start(
                "qwen3:8b",
                _pull_von(
                    {"status": "pulling manifest"},
                    {"status": "pulling a", "digest": "a", "total": 100, "completed": 50},
                    {"status": "pulling b", "digest": "b", "total": 300, "completed": 0},
                    {"status": "pulling a", "digest": "a", "total": 100, "completed": 100},
                    {"status": "verifying sha256 digest"},
                    {"status": "success"},
                ),
            )
            await asyncio.sleep(0.05)
            return m.jobs()[0]

        job = asyncio.run(lauf())
        assert job.state is PullState.done
        assert job.total == 400
        assert job.completed == 400
        assert job.finished_at is not None

    def test_fehler_von_ollama_wird_gemeldet(self):
        async def lauf():
            m = PullManager()
            m.start("gibtsnicht:1b", _pull_von({"error": "pull model manifest: file does not exist"}))
            await asyncio.sleep(0.05)
            return m.jobs()[0]

        job = asyncio.run(lauf())
        assert job.state is PullState.failed
        assert "does not exist" in job.error

    def test_ende_ohne_success_ist_kein_erfolg(self):
        async def lauf():
            m = PullManager()
            m.start("x:1b", _pull_von({"status": "pulling manifest"}))
            await asyncio.sleep(0.05)
            return m.jobs()[0]

        assert asyncio.run(lauf()).state is PullState.failed

    def test_nur_ein_download_zur_zeit_und_abbrechbar(self):
        async def lauf():
            m = PullManager()
            m.start("a:1b", _pull_von(*[{"status": "x"}] * 100, pause=0.01))
            with pytest.raises(PullBusy):
                m.start("b:1b", _pull_von({"status": "success"}))
            assert m.cancel("a:1b")
            await asyncio.sleep(0.05)
            return m.jobs()[0]

        job = asyncio.run(lauf())
        assert job.state is PullState.cancelled


# ---------------------------------------------------------------------------
# Routen
# ---------------------------------------------------------------------------


class PullFake(FakeBackend):
    def __init__(self, *a, **k) -> None:
        super().__init__(*a, **k)
        self.geladen: list = []

    async def load(self, model, opts):
        self.geladen.append((model, opts))

    async def pull(self, model):
        yield {"status": "success"}


@pytest.fixture
def client(monkeypatch):
    backends = {
        BackendId.ollama: PullFake(BackendId.ollama),
        BackendId.lmstudio: PullFake(BackendId.lmstudio),
    }
    # Die LM-Studio-Attrappe soll ablehnen wie das echte Backend.
    backends[BackendId.lmstudio].check_chat_load = (  # type: ignore[method-assign]
        lambda opts: LmStudioBackend.check_chat_load(None, opts)  # type: ignore[arg-type]
    )
    cfg = dataclasses.replace(gw.CONFIG, token=TOKEN, allow_pull=True, max_context=65536)
    monkeypatch.setattr(gw, "CONFIG", cfg)
    with TestClient(gw.app) as c:
        monkeypatch.setattr(gw, "_backends", backends)
        monkeypatch.setattr(gw, "_pulls", PullManager())
        c.backends = backends  # type: ignore[attr-defined]
        yield c


def _chat(backend: str, load: dict) -> dict:
    return {
        "backend": backend,
        "model": "m1",
        "messages": [{"role": "user", "content": "hi"}],
        "load": load,
    }


class TestRouten:
    def test_health_nennt_faehigkeiten(self, client):
        j = client.get("/v1/health", headers=auth()).json()
        assert j["pull_enabled"] is True
        assert j["max_context"] == 65536

    def test_laden(self, client):
        r = client.post(
            "/v1/models/load",
            headers=auth(),
            json={"backend": "ollama", "model": "m1", "load": {"context_length": 8192}},
        )
        assert r.status_code == 200
        model, opts = client.backends[BackendId.ollama].geladen[0]
        assert (model, opts.context_length) == ("m1", 8192)

    def test_kontext_ueber_der_grenze_wird_abgelehnt(self, client):
        r = client.post(
            "/v1/models/load",
            headers=auth(),
            json={"backend": "ollama", "model": "m1", "load": {"context_length": 131072}},
        )
        assert r.status_code == 400
        assert "GATEWAY_MAX_CONTEXT" in r.json()["detail"]
        r = client.post("/v1/chat", headers=auth(), json=_chat("ollama", {"context_length": 131072}))
        assert r.status_code == 400

    def test_chat_mit_ladeoptionen(self, client):
        r = client.post("/v1/chat", headers=auth(), json=_chat("ollama", {"context_length": 8192, "keep_alive": 600}))
        assert r.status_code == 200
        assert any(e["type"] == "done" for e in sse(r))
        seen = client.backends[BackendId.ollama].seen[-1]
        assert seen.load.context_length == 8192

    def test_lm_studio_chat_mit_kontext_400_statt_still(self, client):
        r = client.post("/v1/chat", headers=auth(), json=_chat("lmstudio", {"context_length": 8192}))
        assert r.status_code == 400
        assert "Laden" in r.json()["detail"]

    def test_download_ablauf(self, client):
        r = client.post("/v1/models/pull", headers=auth(), json={"model": "qwen3:8b"})
        assert r.status_code == 202
        jobs = client.get("/v1/models/pulls", headers=auth()).json()
        assert jobs["enabled"] is True
        assert jobs["jobs"][0]["model"] == "qwen3:8b"

    def test_download_ohne_token_401(self, client):
        assert client.post("/v1/models/pull", json={"model": "qwen3:8b"}).status_code == 401

    def test_download_mit_schalter_als_name_400(self, client):
        r = client.post("/v1/models/pull", headers=auth(), json={"model": "--insecure"})
        assert r.status_code == 400

    def test_download_aus_403(self, client, monkeypatch):
        monkeypatch.setattr(gw, "CONFIG", dataclasses.replace(gw.CONFIG, allow_pull=False))
        r = client.post("/v1/models/pull", headers=auth(), json={"model": "qwen3:8b"})
        assert r.status_code == 403
        assert "GATEWAY_ALLOW_PULL" in r.json()["detail"]
        assert client.get("/v1/models/pulls", headers=auth()).json()["enabled"] is False

    def test_agenten_token_kommt_nicht_an_laden_und_download(self, client, monkeypatch):
        agent = "agenten-token-mit-genug-laenge"
        monkeypatch.setattr(gw, "CONFIG", dataclasses.replace(gw.CONFIG, agent_token=agent))
        h = {"Authorization": f"Bearer {agent}"}
        assert client.post("/v1/models/pull", headers=h, json={"model": "qwen3:8b"}).status_code == 401
        assert client.post(
            "/v1/models/load", headers=h, json={"backend": "ollama", "model": "m1"}
        ).status_code == 401


# ---------------------------------------------------------------------------
# Abschaetzung
# ---------------------------------------------------------------------------


class TestKvAbschaetzung:
    def test_qwen3_8b(self, monkeypatch):
        from gateway.backends.ollama import kv_bytes_per_token

        monkeypatch.delenv("OLLAMA_KV_CACHE_TYPE", raising=False)
        info = {
            "general.architecture": "qwen3",
            "qwen3.block_count": 36,
            "qwen3.attention.head_count": 32,
            "qwen3.attention.head_count_kv": 8,
            "qwen3.attention.key_length": 128,
            "qwen3.attention.value_length": 128,
        }
        # 36 Schichten x 8 Koepfe x (128 + 128) x 2 Bytes = 144 KiB pro Token
        assert kv_bytes_per_token(info).value == 36 * 8 * 256 * 2

    def test_quantisierter_cache_halbiert(self, monkeypatch):
        from gateway.backends.ollama import kv_bytes_per_token

        monkeypatch.setenv("OLLAMA_KV_CACHE_TYPE", "q8_0")
        info = {
            "general.architecture": "llama",
            "llama.block_count": 32,
            "llama.attention.head_count": 32,
            "llama.attention.head_count_kv": 8,
            "llama.embedding_length": 4096,
        }
        fact = kv_bytes_per_token(info)
        assert fact.value == 32 * 8 * (128 + 128) * 1
        assert "q8_0" in fact.note

    def test_koepfe_pro_schicht(self, monkeypatch):
        from gateway.backends.ollama import kv_bytes_per_token

        monkeypatch.delenv("OLLAMA_KV_CACHE_TYPE", raising=False)
        info = {
            "general.architecture": "x",
            "x.block_count": 3,
            "x.attention.head_count_kv": [4, 0, 4],
            "x.attention.key_length": 64,
            "x.attention.value_length": 64,
        }
        assert kv_bytes_per_token(info).value == 8 * 128 * 2

    def test_fehlende_daten_sind_unbekannt_statt_null(self):
        from gateway.backends.ollama import kv_bytes_per_token

        fact = kv_bytes_per_token({"general.architecture": "neu"})
        assert fact.value is None
        assert fact.certainty.value == "unknown"
