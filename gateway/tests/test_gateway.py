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
from gateway import openai_api, research
from gateway.backends.base import (
    Backend,
    Delta,
    Done,
    Reasoning,
    Status,
    ToolCalls,
)
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
    ToolCall,
)

TOKEN = "test-token-mit-genug-laenge"


class FakeBackend(Backend):
    """Liefert feste Antworten und kann auf Wunsch scheitern."""

    def __init__(self, backend_id: BackendId, *, fail_models: bool = False) -> None:
        self.id = backend_id
        self.fail_models = fail_models
        self.seen: list[ChatRequest] = []
        #: Wenn gesetzt, antwortet die Attrappe mit einem anderen Modell -
        #: so verhaelt sich LM Studio, wenn ein anderes geladen ist.
        self.served_model: str | None = None
        #: Wenn True, fordert die Attrappe einen Werkzeugaufruf an, sobald
        #: der Aufrufer Werkzeuge anbietet.
        self.ruft_werkzeug_auf = True

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
        if req.tools and self.ruft_werkzeug_auf:
            yield ToolCalls([
                ToolCall(id="call_1", name="wetter",
                         arguments='{"stadt": "Berlin"}')
            ])
            yield Done(
                ChatMetrics(
                    total_ms=Fact.of(12.0),
                    stop_reason=Fact.of("tool_calls"),
                    served_model=Fact.of(self.served_model or req.model),
                )
            )
            return
        yield Reasoning("erst denken")
        yield Delta("dann ")
        yield Delta("antworten")
        yield Done(
            ChatMetrics(
                total_ms=Fact.of(12.0),
                served_model=Fact.of(self.served_model or req.model),
            )
        )

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
    # agent_token und Recherche bewusst aus: sonst entscheidet eine lokale
    # .env darueber, was der Test vorfindet.
    cfg = dataclasses.replace(
        gw.CONFIG, token=TOKEN, agent_token="", research_enabled=False
    )
    monkeypatch.setattr(gw, "CONFIG", cfg)
    monkeypatch.setattr(openai_api, "CONFIG", cfg)
    monkeypatch.setattr(research, "CONFIG", cfg)
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
    def _cfg(self, token: str, agent_token: str = "") -> Config:
        return Config(
            token=token,
            agent_token=agent_token,
            ollama_url="",
            lmstudio_url="",
            bind_host="0.0.0.0",
            bind_port=1,
            request_timeout=1,
            telemetry_interval=1,
            max_request_bytes=1024,
            research_enabled=False,
            search_provider="none",
            searxng_url="",
            brave_key="",
            research_timeout=5,
            research_max_results=3,
            research_max_chars=1000,
        )

    def test_leerer_token_wird_abgelehnt(self):
        with pytest.raises(ConfigError, match="leer"):
            self._cfg("").check()

    def test_kurzer_token_wird_abgelehnt(self):
        with pytest.raises(ConfigError, match="zu kurz"):
            self._cfg("kurz").check()

    def test_langer_token_geht_durch(self):
        self._cfg(TOKEN).check()

    def test_agenten_oberflaeche_ist_ohne_token_aus(self):
        assert self._cfg(TOKEN).agents_enabled is False

    def test_kurzes_agenten_token_wird_abgelehnt(self):
        with pytest.raises(ConfigError, match="GATEWAY_AGENT_TOKEN"):
            self._cfg(TOKEN, agent_token="kurz").check()

    def test_gleiches_agenten_token_wird_abgelehnt(self):
        # Sonst laesst sich der Agentenzugang nicht getrennt zurueckziehen.
        with pytest.raises(ConfigError, match="identisch"):
            self._cfg(TOKEN, agent_token=TOKEN).check()

    def test_eigenes_agenten_token_schaltet_die_oberflaeche_ein(self):
        cfg = self._cfg(TOKEN, agent_token="agent-token-mit-genug-laenge")
        cfg.check()
        assert cfg.agents_enabled is True

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


# ---------------------------------------------------------------------------
# OpenAI-kompatible Oberflaeche
# ---------------------------------------------------------------------------

AGENT_TOKEN = "agent-token-mit-genug-laenge"


@pytest.fixture
def agent_client(backends, monkeypatch):
    cfg = dataclasses.replace(
        gw.CONFIG, token=TOKEN, agent_token=AGENT_TOKEN, research_enabled=False
    )
    # Jedes Modul haelt eine eigene Referenz auf CONFIG.
    monkeypatch.setattr(gw, "CONFIG", cfg)
    monkeypatch.setattr(openai_api, "CONFIG", cfg)
    monkeypatch.setattr(research, "CONFIG", cfg)
    with TestClient(gw.app) as c:
        gw.app.state.backends = backends
        yield c


def agent_auth() -> dict:
    return {"Authorization": "Bearer " + AGENT_TOKEN}


class TestOpenAiAuth:
    def test_ohne_agenten_token_ist_die_oberflaeche_nicht_da(self, client):
        # `client` setzt kein GATEWAY_AGENT_TOKEN: die Routen sollen sich
        # verhalten, als gaebe es sie nicht.
        r = client.get("/openai/v1/models", headers=auth())
        assert r.status_code == 404

    def test_app_token_oeffnet_die_agenten_oberflaeche_nicht(self, agent_client):
        # Der ganze Zweck des getrennten Tokens.
        r = agent_client.get("/openai/v1/models", headers=auth())
        assert r.status_code == 401

    def test_agenten_token_oeffnet_die_app_api_nicht(self, agent_client):
        r = agent_client.get("/v1/health", headers=agent_auth())
        assert r.status_code == 401

    def test_mit_agenten_token_200(self, agent_client):
        assert agent_client.get("/openai/v1/models", headers=agent_auth()).status_code == 200

    def test_fehler_kommt_im_openai_format(self, agent_client):
        # OpenAI-Clients lesen `error.message` auf oberster Ebene. Unter
        # `detail` verpackt finden sie es nicht und melden "unknown error".
        r = agent_client.get("/openai/v1/models", headers={"Authorization": "Bearer x"})
        assert r.status_code == 401
        assert "detail" not in r.json()
        assert r.json()["error"]["message"]
        assert r.json()["error"]["type"]

    def test_app_api_behaelt_ihre_fehlerform(self, client):
        # Die App liest `detail` - diese Form darf sich nicht mitaendern.
        r = client.get("/v1/health", headers={"Authorization": "Bearer falsch"})
        assert r.json()["detail"] == "Ungueltiger Token"


class TestOpenAiModels:
    def test_modelle_tragen_ihr_backend_im_namen(self, agent_client):
        data = agent_client.get("/openai/v1/models", headers=agent_auth()).json()

        assert data["object"] == "list"
        ids = {m["id"] for m in data["data"]}
        assert ids == {"ollama/m1", "lmstudio/m1"}
        assert all(m["object"] == "model" for m in data["data"])

    def test_totes_backend_leert_die_liste_nicht(self, agent_client, backends):
        backends[BackendId.lmstudio].fail_models = True
        data = agent_client.get("/openai/v1/models", headers=agent_auth()).json()
        assert [m["id"] for m in data["data"]] == ["ollama/m1"]


def _completion(agent_client, **extra):
    body = {"model": "ollama/m1", "messages": [{"role": "user", "content": "hi"}]}
    body.update(extra)
    return agent_client.post("/openai/v1/chat/completions", headers=agent_auth(), json=body)


class TestOpenAiChat:
    def test_antwort_ohne_streaming(self, agent_client):
        data = _completion(agent_client).json()

        assert data["object"] == "chat.completion"
        assert data["model"] == "ollama/m1"
        choice = data["choices"][0]
        assert choice["message"]["content"] == "dann antworten"
        assert choice["finish_reason"] == "stop"

    def test_denkschritte_stehen_getrennt_vom_antworttext(self, agent_client):
        message = _completion(agent_client).json()["choices"][0]["message"]

        assert message["reasoning_content"] == "erst denken"
        assert "erst denken" not in message["content"]

    def test_stream_endet_mit_done_marke(self, agent_client):
        r = _completion(agent_client, stream=True)
        roh = [l[5:].strip() for l in r.text.splitlines() if l.startswith("data:")]

        assert roh[-1] == "[DONE]"
        chunks = [json.loads(x) for x in roh[:-1]]
        assert chunks[0]["choices"][0]["delta"] == {"role": "assistant"}
        assert all(c["object"] == "chat.completion.chunk" for c in chunks)

        text = "".join(
            c["choices"][0]["delta"].get("content", "")
            for c in chunks
            if c["choices"]
        )
        assert text == "dann antworten"
        assert chunks[-1]["choices"][0]["finish_reason"] == "stop"

    def test_stream_traegt_denkschritte_in_eigenem_feld(self, agent_client):
        r = _completion(agent_client, stream=True)
        chunks = [
            json.loads(l[5:]) for l in r.text.splitlines()
            if l.startswith("data:") and l[5:].strip() != "[DONE]"
        ]
        reasoning = "".join(
            c["choices"][0]["delta"].get("reasoning_content", "")
            for c in chunks if c["choices"]
        )
        assert reasoning == "erst denken"

    def test_unbekanntes_modell_gibt_404_mit_hinweis(self, agent_client):
        r = _completion(agent_client, model="gibtsnicht")
        assert r.status_code == 404
        assert "Praefix" in r.json()["error"]["message"]

    def test_mehrdeutiges_modell_verlangt_praefix(self, agent_client):
        # "m1" gibt es auf beiden Attrappen.
        r = _completion(agent_client, model="m1")
        assert r.status_code == 400
        assert "mehreren Backends" in r.json()["error"]["message"]

    def test_unbekannte_felder_kippen_die_anfrage_nicht(self, agent_client):
        # Clients schicken presence_penalty, logit_bias, user, seed ...
        r = _completion(
            agent_client, presence_penalty=0.5, logit_bias={}, user="wer", seed=7
        )
        assert r.status_code == 200

    def test_max_completion_tokens_wird_verstanden(self, agent_client, backends):
        _completion(agent_client, max_completion_tokens=64)
        assert backends[BackendId.ollama].seen[-1].max_tokens == 64

    def test_bilder_nur_als_data_url(self, agent_client, backends):
        # Eine fremde URL wuerde das Gateway zu einem Downloader machen, der
        # Adressen aus dem Nachrichteninhalt abruft.
        _completion(
            agent_client,
            messages=[{
                "role": "user",
                "content": [
                    {"type": "text", "text": "was ist das"},
                    {"type": "image_url",
                     "image_url": {"url": "data:image/png;base64,AAAA"}},
                    {"type": "image_url",
                     "image_url": {"url": "https://example.invalid/bild.png"}},
                ],
            }],
        )
        gesehen = backends[BackendId.ollama].seen[-1].messages[0]
        assert gesehen.images == ["AAAA"]
        assert gesehen.content == "was ist das"

    def test_antwort_nennt_das_modell_das_wirklich_geantwortet_hat(
        self, agent_client, backends
    ):
        # LM Studio beantwortet jeden Namen mit dem geladenen Modell. Den
        # angefragten zurueckzugeben waere eine Behauptung.
        backends[BackendId.ollama].served_model = "ein-ganz-anderes"
        data = _completion(agent_client).json()

        assert data["model"] == "ollama/ein-ganz-anderes"

    def test_stream_nennt_ebenfalls_das_tatsaechliche_modell(
        self, agent_client, backends
    ):
        backends[BackendId.ollama].served_model = "ein-ganz-anderes"
        r = _completion(agent_client, stream=True)
        chunks = [
            json.loads(l[5:]) for l in r.text.splitlines()
            if l.startswith("data:") and l[5:].strip() != "[DONE]"
        ]
        assert chunks[-1]["model"] == "ollama/ein-ganz-anderes"


class TestOpenAiParameter:
    """Was gesetzt wird, muss ankommen; was nicht geht, muss auffallen."""

    def test_generierungsparameter_kommen_beim_backend_an(self, agent_client, backends):
        _completion(
            agent_client,
            temperature=0.3,
            top_p=0.9,
            max_tokens=128,
            stop=["ENDE"],
            seed=42,
            presence_penalty=0.1,
            frequency_penalty=0.2,
            response_format={"type": "json_object"},
        )
        req = backends[BackendId.ollama].seen[-1]

        assert req.temperature == 0.3
        assert req.top_p == 0.9
        assert req.max_tokens == 128
        assert req.stop == ["ENDE"]
        assert req.seed == 42
        assert req.presence_penalty == 0.1
        assert req.frequency_penalty == 0.2
        assert req.json_mode is True

    def test_stop_als_einzelner_string(self, agent_client, backends):
        _completion(agent_client, stop="ENDE")
        assert backends[BackendId.ollama].seen[-1].stop == ["ENDE"]

    def test_n_groesser_eins_wird_abgelehnt(self, agent_client):
        r = _completion(agent_client, n=3)
        assert r.status_code == 400
        assert "n=3" in r.json()["error"]["message"]

    def test_n_gleich_eins_geht_durch(self, agent_client):
        assert _completion(agent_client, n=1).status_code == 200

    def test_logprobs_werden_abgelehnt(self, agent_client):
        assert _completion(agent_client, logprobs=True).status_code == 400

    def test_json_schema_wird_abgelehnt_json_object_nicht(self, agent_client):
        schema = _completion(
            agent_client, response_format={"type": "json_schema", "json_schema": {}}
        )
        assert schema.status_code == 400
        objekt = _completion(agent_client, response_format={"type": "json_object"})
        assert objekt.status_code == 200

WERKZEUG = {
    "type": "function",
    "function": {
        "name": "wetter",
        "description": "Wetter fuer eine Stadt",
        "parameters": {
            "type": "object",
            "properties": {"stadt": {"type": "string"}},
            "required": ["stadt"],
        },
    },
}


class TestWerkzeugaufrufe:
    """Das Gateway reicht Aufrufe durch - es fuehrt nichts aus."""

    def test_werkzeuge_erreichen_das_backend_unveraendert(self, agent_client, backends):
        _completion(agent_client, tools=[WERKZEUG])
        assert backends[BackendId.ollama].seen[-1].tools == [WERKZEUG]

    def test_tool_choice_wird_durchgereicht(self, agent_client, backends):
        _completion(agent_client, tools=[WERKZEUG], tool_choice="required")
        assert backends[BackendId.ollama].seen[-1].tool_choice == "required"

    def test_antwort_traegt_die_aufrufe_im_openai_format(self, agent_client):
        data = _completion(agent_client, tools=[WERKZEUG]).json()
        choice = data["choices"][0]

        assert choice["finish_reason"] == "tool_calls"
        aufruf = choice["message"]["tool_calls"][0]
        assert aufruf["type"] == "function"
        assert aufruf["function"]["name"] == "wetter"
        # Argumente bleiben ein String, unveraendert vom Modell.
        assert json.loads(aufruf["function"]["arguments"]) == {"stadt": "Berlin"}
        assert choice["message"]["content"] is None

    def test_stream_liefert_die_aufrufe_vollstaendig(self, agent_client):
        r = _completion(agent_client, tools=[WERKZEUG], stream=True)
        chunks = [
            json.loads(l[5:]) for l in r.text.splitlines()
            if l.startswith("data:") and l[5:].strip() != "[DONE]"
        ]
        aufrufe = [
            tc for c in chunks for ch in c["choices"]
            for tc in (ch["delta"].get("tool_calls") or [])
        ]

        assert len(aufrufe) == 1, "ein Aufruf, nicht in Fragmenten"
        assert aufrufe[0]["index"] == 0
        assert aufrufe[0]["function"]["name"] == "wetter"
        assert json.loads(aufrufe[0]["function"]["arguments"]) == {"stadt": "Berlin"}
        assert chunks[-1]["choices"][0]["finish_reason"] == "tool_calls"

    def test_werkzeugergebnis_geht_zurueck_ins_gespraech(self, agent_client, backends):
        # Der zweite Zug: Aufruf und Ergebnis kommen als Verlauf zurueck.
        backends[BackendId.ollama].ruft_werkzeug_auf = False
        _completion(
            agent_client,
            tools=[WERKZEUG],
            messages=[
                {"role": "user", "content": "Wetter in Berlin?"},
                {
                    "role": "assistant",
                    "content": None,
                    "tool_calls": [{
                        "id": "call_1", "type": "function",
                        "function": {"name": "wetter",
                                     "arguments": '{"stadt": "Berlin"}'},
                    }],
                },
                {"role": "tool", "tool_call_id": "call_1", "name": "wetter",
                 "content": "12 Grad, bewoelkt"},
            ],
        )
        verlauf = backends[BackendId.ollama].seen[-1].messages

        assert verlauf[1].tool_calls[0].name == "wetter"
        assert verlauf[1].tool_calls[0].arguments == '{"stadt": "Berlin"}'
        assert verlauf[2].role == "tool"
        assert verlauf[2].content == "12 Grad, bewoelkt"
        assert verlauf[2].tool_call_id == "call_1"
        # Ollama ordnet ueber den Namen zu, nicht ueber die Id.
        assert verlauf[2].tool_name == "wetter"

    def test_ohne_werkzeuge_bleibt_alles_wie_bisher(self, agent_client):
        data = _completion(agent_client).json()
        assert data["choices"][0]["message"]["content"] == "dann antworten"
        assert "tool_calls" not in data["choices"][0]["message"]
