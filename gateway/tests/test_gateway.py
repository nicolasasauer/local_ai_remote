"""Tests fuer das Gateway.

Die Backends sind hier durch Attrappen ersetzt: die Tests sollen auch dann
laufen, wenn weder Ollama noch LM Studio gestartet ist.
"""

from __future__ import annotations

import dataclasses
import json
import os
from typing import AsyncIterator

import pytest
from fastapi.testclient import TestClient

from gateway import main as gw
from gateway.backends.base import Backend, Delta, Done, Reasoning, Status
from gateway.config import Config, ConfigError, _load_env_file
from gateway.schema import (
    BackendHealth,
    BackendId,
    Certainty,
    ChatMetrics,
    ChatRequest,
    Fact,
    ModelEntry,
    ModelState,
)

TOKEN = "test-token-mit-genug-laenge"


class FakeBackend(Backend):
    """Liefert feste Antworten und kann auf Wunsch scheitern."""

    def __init__(self, backend_id: BackendId, *, fail_models: bool = False) -> None:
        self.id = backend_id
        self.fail_models = fail_models
        self.seen: list[ChatRequest] = []

    async def health(self) -> BackendHealth:
        return BackendHealth(backend=self.id, reachable=True, version=Fact.of("1.0"))

    async def list_models(self) -> list[ModelEntry]:
        if self.fail_models:
            raise RuntimeError("Backend nicht erreichbar")
        return [
            ModelEntry(
                id="m1",
                label="m1",
                backend=self.id,
                state=ModelState.loaded,
                disk_bytes=Fact.of(123),
                vram_bytes=Fact[int].unsupported_because("kennt dieses Backend nicht"),
            )
        ]

    async def stream_chat(self, req: ChatRequest) -> AsyncIterator:
        self.seen.append(req)
        yield Status("generating", None)
        yield Reasoning("erst denken")
        yield Delta("dann ")
        yield Delta("antworten")
        yield Done(ChatMetrics(total_ms=Fact.of(12.0)))

    async def set_keep_alive(self, model: str, *, pin: bool) -> None:
        return None


@pytest.fixture
def backends():
    return {
        BackendId.ollama: FakeBackend(BackendId.ollama),
        BackendId.lmstudio: FakeBackend(BackendId.lmstudio),
    }


@pytest.fixture
def client(backends, monkeypatch):
    # Config ist frozen, also die ganze Instanz ersetzen statt eines Feldes.
    monkeypatch.setattr(gw, "CONFIG", dataclasses.replace(gw.CONFIG, token=TOKEN))
    with TestClient(gw.app) as c:
        # Nach dem startup-Hook setzen, sonst ueberschreiben ihn die echten
        # Adapter wieder.
        monkeypatch.setattr(gw, "_backends", backends)
        yield c


def auth() -> dict:
    return {"Authorization": "Bearer " + TOKEN}


def sse(response) -> list:
    return [
        json.loads(line[5:])
        for line in response.text.splitlines()
        if line.startswith("data:")
    ]


class TestAuth:
    def test_ohne_token_401(self, client):
        assert client.get("/v1/health").status_code == 401

    def test_falscher_token_401(self, client):
        r = client.get("/v1/health", headers={"Authorization": "Bearer falsch"})
        assert r.status_code == 401

    def test_mit_token_200(self, client):
        assert client.get("/v1/health", headers=auth()).status_code == 200

    def test_telemetrie_weist_falschen_token_ab(self, client):
        with pytest.raises(Exception):
            with client.websocket_connect("/v1/telemetry?token=falsch"):
                pass


class TestConfig:
    def _cfg(self, token: str) -> Config:
        return Config(
            token=token,
            ollama_url="",
            lmstudio_url="",
            bind_host="0.0.0.0",
            bind_port=1,
            request_timeout=1,
            telemetry_interval=1,
        )

    def test_leerer_token_wird_abgelehnt(self):
        with pytest.raises(ConfigError, match="leer"):
            self._cfg("").check()

    def test_kurzer_token_wird_abgelehnt(self):
        with pytest.raises(ConfigError, match="zu kurz"):
            self._cfg("kurz").check()

    def test_langer_token_geht_durch(self):
        self._cfg(TOKEN).check()

    def test_env_datei_wird_gelesen(self, tmp_path, monkeypatch):
        # Ohne dieses Laden bliebe GATEWAY_TOKEN leer und die Auth still aus.
        env = tmp_path / ".env"
        env.write_text('GATEWAY_TOKEN="aus-der-datei"\n# Kommentar\n', encoding="utf-8")
        monkeypatch.delenv("GATEWAY_TOKEN", raising=False)
        _load_env_file(env)
        assert os.environ["GATEWAY_TOKEN"] == "aus-der-datei"

    def test_umgebung_schlaegt_datei(self, tmp_path, monkeypatch):
        env = tmp_path / ".env"
        env.write_text("GATEWAY_TOKEN=aus-der-datei\n", encoding="utf-8")
        monkeypatch.setenv("GATEWAY_TOKEN", "aus-der-umgebung")
        _load_env_file(env)
        assert os.environ["GATEWAY_TOKEN"] == "aus-der-umgebung"


class TestModels:
    def test_ausgefallenes_backend_blockiert_die_liste_nicht(self, client, backends):
        backends[BackendId.lmstudio].fail_models = True
        data = client.get("/v1/models", headers=auth()).json()

        assert [m["id"] for m in data["models"]] == ["m1"]
        assert data["errors"][0]["backend"] == "lmstudio"
        assert "nicht erreichbar" in data["errors"][0]["message"]

    def test_fehlende_werte_reisen_mit_begruendung(self, client):
        model = client.get("/v1/models", headers=auth()).json()["models"][0]

        assert model["disk_bytes"]["value"] == 123
        assert model["disk_bytes"]["certainty"] == Certainty.known.value
        assert model["vram_bytes"]["certainty"] == Certainty.unsupported.value
        assert model["vram_bytes"]["note"], "ohne Begruendung ist die Luecke wertlos"


def _chat(client, **extra):
    body = {
        "backend": "ollama",
        "model": "m1",
        "messages": [{"role": "user", "content": "hi"}],
    }
    body.update(extra)
    return sse(client.post("/v1/chat", headers=auth(), json=body))


class TestChat:
    def test_denkschritte_kommen_als_eigener_typ(self, client):
        # Kern des Blockers: Reasoning-Modelle schreiben ihre Tokens nach
        # `thinking`. Landen die nicht im Stream, bleibt die Antwort leer.
        events = _chat(client)

        reasoning = [e for e in events if e["type"] == "reasoning"]
        assert reasoning and reasoning[0]["text"] == "erst denken"

        deltas = "".join(e["text"] for e in events if e["type"] == "delta")
        assert deltas == "dann antworten"
        assert "erst denken" not in deltas, "Denkschritte sind nicht die Antwort"

    def test_stream_beginnt_mit_accepted_und_endet_mit_done(self, client):
        events = _chat(client)

        assert events[0] == {"type": "status", "state": "accepted", "note": None}
        assert events[-1]["type"] == "done"
        assert events[-1]["metrics"]["total_ms"]["value"] == 12.0

    def test_think_wird_durchgereicht(self, client, backends):
        _chat(client, think=True)
        assert backends[BackendId.ollama].seen[-1].think is True

    def test_think_ist_ohne_angabe_offen(self, client, backends):
        _chat(client)
        assert backends[BackendId.ollama].seen[-1].think is None
