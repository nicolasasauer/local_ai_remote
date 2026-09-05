"""Responses-API: die beiden Normalisierungen, ohne die Codex nicht laeuft.

Beide Backends implementieren die Route nativ, das Gateway leitet weiter. Zwei
Dinge muss es dabei geraderuecken - sonst endet jede Codex-Sitzung mit
HTTP 500, bevor ein einziges Token erzeugt wurde.
"""

from __future__ import annotations

import dataclasses
import json

import httpx
import pytest
from fastapi.testclient import TestClient

from gateway import main as gw
from gateway import openai_api, responses_api
from gateway.responses_api import falte_systemnachrichten, normalisiere_werkzeuge

from .test_gateway import AGENT_TOKEN, TOKEN, agent_auth, backends  # noqa: F401


class TestWerkzeugliste:
    """Codex bietet eingebaute Werkzeugtypen an, die kein lokales Backend
    kennt. Ollama lehnt deswegen die *gesamte* Anfrage ab."""

    def test_funktionen_bleiben(self):
        werkzeuge = [
            {"type": "function", "name": "shell_command"},
            {"type": "function", "name": "view_image"},
        ]
        behalten, verworfen = normalisiere_werkzeuge(werkzeuge)
        assert behalten == werkzeuge
        assert verworfen == []

    def test_eingebaute_typen_fliegen_raus(self):
        behalten, verworfen = normalisiere_werkzeuge([
            {"type": "function", "name": "shell_command"},
            {"type": "image_generation"},
            {"type": "web_search"},
            {"type": "namespace"},
        ])
        assert [w["name"] for w in behalten] == ["shell_command"]
        assert sorted(verworfen) == ["image_generation", "namespace", "web_search"]

    def test_unfug_kippt_nicht(self):
        assert normalisiere_werkzeuge(None) == ([], [])
        assert normalisiere_werkzeuge(["kein Objekt"]) == ([], [])


class TestSystemnachrichten:
    """Codex schickt `instructions` *und* einen `developer`-Eintrag. Ollama
    macht daraus zwei Systemnachrichten; strenge Chat-Vorlagen brechen mit
    "System message must be at the beginning" ab."""

    def test_developer_wird_in_instructions_gefaltet(self):
        payload = {
            "instructions": "Du bist ein Agent.",
            "input": [
                {"role": "developer", "type": "message",
                 "content": [{"type": "input_text", "text": "Projektregeln"}]},
                {"role": "user", "type": "message", "content": "Hallo"},
            ],
        }
        assert falte_systemnachrichten(payload) is True

        # Inhalt bleibt vollstaendig, Reihenfolge bleibt erhalten.
        assert payload["instructions"] == "Du bist ein Agent.\n\nProjektregeln"
        assert [e["role"] for e in payload["input"]] == ["user"]

    def test_ohne_developer_bleibt_alles_wie_es_war(self):
        payload = {
            "instructions": "Du bist ein Agent.",
            "input": [{"role": "user", "type": "message", "content": "Hallo"}],
        }
        assert falte_systemnachrichten(payload) is False
        assert payload["instructions"] == "Du bist ein Agent."
        assert len(payload["input"]) == 1

    def test_ohne_instructions_wird_developer_zur_anweisung(self):
        payload = {"input": [
            {"role": "developer", "content": "Nur Deutsch"},
            {"role": "user", "content": "Hallo"},
        ]}
        assert falte_systemnachrichten(payload) is True
        assert payload["instructions"] == "Nur Deutsch"

    def test_system_rolle_wird_genauso_behandelt(self):
        payload = {"input": [
            {"role": "system", "content": "Regeln"},
            {"role": "user", "content": "Hallo"},
        ]}
        assert falte_systemnachrichten(payload) is True
        assert payload["instructions"] == "Regeln"
        assert [e["role"] for e in payload["input"]] == ["user"]

    def test_input_als_string_bleibt_unangetastet(self):
        payload = {"input": "Einfach nur Text"}
        assert falte_systemnachrichten(payload) is False
        assert payload["input"] == "Einfach nur Text"


class _FakeBackend:
    """Nimmt die Weiterleitung entgegen und merkt sich, was ankam."""

    def __init__(self) -> None:
        self.gesehen: list[dict] = []
        self.base_url = "http://backend"

        def handler(request: httpx.Request) -> httpx.Response:
            self.gesehen.append(json.loads(request.content))
            return httpx.Response(200, json={
                "id": "resp_1", "object": "response", "status": "completed",
                "model": "m1", "output": [],
            })

        self.http = httpx.AsyncClient(transport=httpx.MockTransport(handler))

    async def list_models(self):
        return []


@pytest.fixture
def responses_client(monkeypatch):
    from gateway.schema import BackendId

    cfg = dataclasses.replace(gw.CONFIG, token=TOKEN, agent_token=AGENT_TOKEN)
    monkeypatch.setattr(gw, "CONFIG", cfg)
    monkeypatch.setattr(openai_api, "CONFIG", cfg)
    monkeypatch.setattr(responses_api, "CONFIG", cfg, raising=False)

    fake = _FakeBackend()
    with TestClient(gw.app) as c:
        gw.app.state.backends = {BackendId.ollama: fake}
        yield c, fake


class TestWeiterleitung:
    def test_praefix_wird_abgeschnitten_und_wieder_angesetzt(self, responses_client):
        client, fake = responses_client
        r = client.post("/openai/v1/responses", headers=agent_auth(), json={
            "model": "ollama/m1", "input": "hi",
        })

        assert r.status_code == 200
        # Das Backend kennt seinen eigenen Namen ohne Praefix ...
        assert fake.gesehen[0]["model"] == "m1"
        # ... der Client bekommt ihn wieder qualifiziert zurueck, damit er ihn
        # wiederverwenden kann.
        assert r.json()["model"] == "ollama/m1"

    def test_normalisierungen_greifen_auf_dem_weg(self, responses_client):
        client, fake = responses_client
        client.post("/openai/v1/responses", headers=agent_auth(), json={
            "model": "ollama/m1",
            "instructions": "Anweisung",
            "input": [
                {"role": "developer", "content": "Regeln"},
                {"role": "user", "content": "Hallo"},
            ],
            "tools": [
                {"type": "function", "name": "shell"},
                {"type": "image_generation"},
            ],
        })
        gesendet = fake.gesehen[0]

        assert [w["type"] for w in gesendet["tools"]] == ["function"]
        assert gesendet["instructions"] == "Anweisung\n\nRegeln"
        assert [e["role"] for e in gesendet["input"]] == ["user"]

    def test_ohne_modell_400(self, responses_client):
        client, _ = responses_client
        r = client.post("/openai/v1/responses", headers=agent_auth(), json={"input": "hi"})
        assert r.status_code == 400
        assert "model" in r.json()["error"]["message"]

    def test_ohne_agenten_token_401(self, responses_client):
        client, _ = responses_client
        r = client.post("/openai/v1/responses", json={"model": "ollama/m1", "input": "hi"})
        assert r.status_code == 401
