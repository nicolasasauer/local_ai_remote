"""Adapter-Tests gegen nachgebaute Backend-Antworten.

Hier wird geprueft, was das Gateway *sendet* und wie es die Antwort liest -
mit `httpx.MockTransport` statt eines laufenden Ollama oder LM Studio. Genau
an diesen Stellen sassen die beiden Fehler, die im Betrieb still blieben:
Ollama liefert Denkschritte nur auf Anforderung, LM Studio Tokenzahlen nur auf
Anforderung.
"""

from __future__ import annotations

import asyncio
import json

import httpx
import pytest

from gateway.backends.base import Delta, Done, Reasoning, Status
from gateway.backends.lmstudio import LmStudioBackend
from gateway.backends.ollama import OllamaBackend
from gateway.schema import BackendId, ChatMessage, ChatRequest


def ndjson(*chunks: dict) -> bytes:
    return b"".join(json.dumps(c).encode() + b"\n" for c in chunks)


def sse(*chunks: dict) -> bytes:
    body = b"".join(b"data: " + json.dumps(c).encode() + b"\n\n" for c in chunks)
    return body + b"data: [DONE]\n\n"


class TroepfelStream(httpx.AsyncByteStream):
    """Gibt die Chunks einzeln und mit Pause aus.

    Ein Mock, der den ganzen Koerper auf einmal liefert, laesst zwischen
    erstem und letztem Token keine Zeit vergehen - die Tempoberechnung waere
    damit nicht pruefbar.
    """

    def __init__(self, chunks: list[dict], pause: float = 0.03) -> None:
        self._chunks = chunks
        self._pause = pause

    async def __aiter__(self):
        for chunk in self._chunks:
            yield b"data: " + json.dumps(chunk).encode() + b"\n\n"
            await asyncio.sleep(self._pause)
        yield b"data: [DONE]\n\n"


def request_of(model: str = "m", **extra) -> ChatRequest:
    return ChatRequest(
        backend=BackendId.ollama,
        model=model,
        messages=[ChatMessage(role="user", content="hi")],
        **extra,
    )


async def collect(backend, req):
    return [event async for event in backend.stream_chat(req)]


# ---------------------------------------------------------------------------
# Ollama
# ---------------------------------------------------------------------------


class TestOllamaDenkschritte:
    def _transport(self, gesendet: list, *, faehigkeiten: list[str]):
        def handler(request: httpx.Request) -> httpx.Response:
            if request.url.path == "/api/show":
                return httpx.Response(200, json={"capabilities": faehigkeiten})
            if request.url.path == "/api/chat":
                gesendet.append(json.loads(request.content))
                return httpx.Response(
                    200,
                    content=ndjson(
                        {"message": {"content": "", "thinking": "erst "}},
                        {"message": {"content": "", "thinking": "denken"}},
                        {"message": {"content": "dann antworten"}},
                        {
                            "message": {"content": ""},
                            "done": True,
                            "done_reason": "stop",
                            "eval_count": 4,
                            "eval_duration": 1_000_000_000,
                            "prompt_eval_count": 7,
                        },
                    ),
                )
            return httpx.Response(404)

        return httpx.MockTransport(handler)

    @pytest.mark.asyncio
    async def test_thinking_wird_zu_reasoning_und_nicht_zur_antwort(self):
        gesendet: list = []
        async with httpx.AsyncClient(
            transport=self._transport(gesendet, faehigkeiten=["thinking"])
        ) as http:
            backend = OllamaBackend("http://ollama", http)
            events = await collect(backend, request_of())

        denken = "".join(e.text for e in events if isinstance(e, Reasoning))
        antwort = "".join(e.text for e in events if isinstance(e, Delta))

        assert denken == "erst denken"
        assert antwort == "dann antworten"
        assert "denken" not in antwort

    @pytest.mark.asyncio
    async def test_think_wird_angefordert_wenn_das_modell_es_kann(self):
        # Ohne dieses Flag liefert Ollama bei Reasoning-Modellen weder
        # `thinking` noch `content` - die Antwort bliebe dauerhaft leer.
        gesendet: list = []
        async with httpx.AsyncClient(
            transport=self._transport(gesendet, faehigkeiten=["completion", "thinking"])
        ) as http:
            await collect(OllamaBackend("http://ollama", http), request_of())

        assert gesendet[0].get("think") is True

    @pytest.mark.asyncio
    async def test_think_bleibt_weg_wenn_das_modell_es_nicht_kann(self):
        gesendet: list = []
        async with httpx.AsyncClient(
            transport=self._transport(gesendet, faehigkeiten=["completion"])
        ) as http:
            await collect(OllamaBackend("http://ollama", http), request_of())

        assert "think" not in gesendet[0]

    @pytest.mark.asyncio
    async def test_ausdrueckliches_think_schlaegt_die_faehigkeit(self):
        gesendet: list = []
        async with httpx.AsyncClient(
            transport=self._transport(gesendet, faehigkeiten=["completion"])
        ) as http:
            await collect(
                OllamaBackend("http://ollama", http), request_of(think=True)
            )

        assert gesendet[0].get("think") is True


# ---------------------------------------------------------------------------
# LM Studio
# ---------------------------------------------------------------------------


class TestLmStudioKennzahlen:
    def _transport(self, gesendet: list, *, mit_usage: bool, served: str = "m"):
        def handler(request: httpx.Request) -> httpx.Response:
            gesendet.append(json.loads(request.content))
            chunks = [
                {"model": served,
                 "choices": [{"delta": {"reasoning_content": "erst denken"}}]},
                {"choices": [{"delta": {"content": "dann antworten"}}]},
                {"choices": [{"delta": {}, "finish_reason": "stop"}]},
            ]
            if mit_usage:
                chunks.append(
                    {
                        "choices": [],
                        "usage": {"prompt_tokens": 18, "completion_tokens": 60},
                    }
                )
            return httpx.Response(
                200,
                headers={"content-type": "text/event-stream"},
                stream=TroepfelStream(chunks),
            )

        return httpx.MockTransport(handler)

    @pytest.mark.asyncio
    async def test_usage_wird_ausdruecklich_angefordert(self):
        # LM Studio schickt im Stream sonst gar kein `usage`, und die
        # Tokenzahlen blieben dauerhaft unbekannt.
        gesendet: list = []
        async with httpx.AsyncClient(
            transport=self._transport(gesendet, mit_usage=True)
        ) as http:
            await collect(LmStudioBackend("http://lmstudio", http), request_of())

        assert gesendet[0]["stream_options"] == {"include_usage": True}

    @pytest.mark.asyncio
    async def test_tokenzahlen_kommen_an(self):
        gesendet: list = []
        async with httpx.AsyncClient(
            transport=self._transport(gesendet, mit_usage=True)
        ) as http:
            events = await collect(
                LmStudioBackend("http://lmstudio", http), request_of()
            )

        done = next(e for e in events if isinstance(e, Done))
        assert done.metrics.prompt_tokens.value == 18
        assert done.metrics.completion_tokens.value == 60

    @pytest.mark.asyncio
    async def test_tempo_wird_berechnet_und_die_herkunft_vermerkt(self):
        gesendet: list = []
        async with httpx.AsyncClient(
            transport=self._transport(gesendet, mit_usage=True)
        ) as http:
            events = await collect(
                LmStudioBackend("http://lmstudio", http), request_of()
            )

        tempo = next(e for e in events if isinstance(e, Done)).metrics.tokens_per_second
        assert tempo.value is not None and tempo.value > 0
        assert "berechnet" in (tempo.note or ""), "Herkunft muss erkennbar bleiben"

    @pytest.mark.asyncio
    async def test_ohne_usage_bleibt_die_zahl_unbekannt_statt_null(self):
        gesendet: list = []
        async with httpx.AsyncClient(
            transport=self._transport(gesendet, mit_usage=False)
        ) as http:
            events = await collect(
                LmStudioBackend("http://lmstudio", http), request_of()
            )

        metrics = next(e for e in events if isinstance(e, Done)).metrics
        assert metrics.completion_tokens.value is None
        assert metrics.completion_tokens.certainty.value == "unknown"
        assert metrics.completion_tokens.note

    @pytest.mark.asyncio
    async def test_reasoning_content_wird_getrennt_gefuehrt(self):
        gesendet: list = []
        async with httpx.AsyncClient(
            transport=self._transport(gesendet, mit_usage=True)
        ) as http:
            events = await collect(
                LmStudioBackend("http://lmstudio", http), request_of()
            )

        assert "".join(e.text for e in events if isinstance(e, Reasoning)) == "erst denken"
        assert "".join(e.text for e in events if isinstance(e, Delta)) == "dann antworten"


class TestLmStudioModellverwechslung:
    """LM Studio beantwortet jeden Namen mit dem gerade geladenen Modell.

    Auch einen frei erfundenen, und mit Status 200. Wer den angefragten Namen
    zurueckgibt, behauptet etwas Falsches - also muss die Abweichung sichtbar
    werden.
    """

    def _transport(self, served: str):
        def handler(request: httpx.Request) -> httpx.Response:
            chunks = [
                {"model": served, "choices": [{"delta": {"content": "ok"}}]},
                {"model": served, "choices": [{"delta": {}, "finish_reason": "stop"}]},
            ]
            return httpx.Response(
                200,
                headers={"content-type": "text/event-stream"},
                stream=TroepfelStream(chunks),
            )

        return httpx.MockTransport(handler)

    @pytest.mark.asyncio
    async def test_abweichung_wird_gemeldet(self):
        async with httpx.AsyncClient(
            transport=self._transport("ein-ganz-anderes")
        ) as http:
            events = await collect(
                LmStudioBackend("http://lmstudio", http), request_of("angefragtes")
            )

        hinweise = [e for e in events if isinstance(e, Status) and e.note]
        assert hinweise, "Die Verwechslung muss im Stream auftauchen"
        assert "ein-ganz-anderes" in hinweise[0].note
        assert "angefragtes" in hinweise[0].note

    @pytest.mark.asyncio
    async def test_tatsaechliches_modell_steht_in_den_kennzahlen(self):
        async with httpx.AsyncClient(
            transport=self._transport("ein-ganz-anderes")
        ) as http:
            events = await collect(
                LmStudioBackend("http://lmstudio", http), request_of("angefragtes")
            )

        done = next(e for e in events if isinstance(e, Done))
        assert done.metrics.served_model.value == "ein-ganz-anderes"

    @pytest.mark.asyncio
    async def test_kein_hinweis_wenn_es_passt(self):
        async with httpx.AsyncClient(transport=self._transport("passt")) as http:
            events = await collect(
                LmStudioBackend("http://lmstudio", http), request_of("passt")
            )

        assert not [e for e in events if isinstance(e, Status) and e.note]


class TestParameterErreichenDasBackend:
    """Was der Aufrufer setzt, muss im Payload landen.

    Ein still verworfener Parameter erzeugt eine Antwort, die anders zustande
    kam als angefordert - und niemand sieht warum.
    """

    def _ollama(self, gesendet: list):
        def handler(request: httpx.Request) -> httpx.Response:
            if request.url.path == "/api/show":
                return httpx.Response(200, json={"capabilities": ["completion"]})
            gesendet.append(json.loads(request.content))
            return httpx.Response(
                200, content=ndjson({"message": {"content": "ok"}, "done": True})
            )

        return httpx.MockTransport(handler)

    def _lmstudio(self, gesendet: list):
        def handler(request: httpx.Request) -> httpx.Response:
            gesendet.append(json.loads(request.content))
            return httpx.Response(
                200,
                headers={"content-type": "text/event-stream"},
                stream=TroepfelStream(
                    [{"choices": [{"delta": {"content": "ok"}, "finish_reason": "stop"}]}]
                ),
            )

        return httpx.MockTransport(handler)

    @pytest.mark.asyncio
    async def test_ollama_bekommt_options_und_format(self):
        gesendet: list = []
        async with httpx.AsyncClient(transport=self._ollama(gesendet)) as http:
            await collect(
                OllamaBackend("http://ollama", http),
                request_of(
                    temperature=0.3,
                    top_p=0.9,
                    max_tokens=128,
                    stop=["ENDE"],
                    seed=42,
                    presence_penalty=0.1,
                    frequency_penalty=0.2,
                    json_mode=True,
                ),
            )

        payload = gesendet[0]
        assert payload["options"]["temperature"] == 0.3
        assert payload["options"]["top_p"] == 0.9
        assert payload["options"]["num_predict"] == 128
        assert payload["options"]["stop"] == ["ENDE"]
        assert payload["options"]["seed"] == 42
        assert payload["options"]["presence_penalty"] == 0.1
        assert payload["options"]["frequency_penalty"] == 0.2
        assert payload["format"] == "json"

    @pytest.mark.asyncio
    async def test_lmstudio_bekommt_die_openai_namen(self):
        gesendet: list = []
        async with httpx.AsyncClient(transport=self._lmstudio(gesendet)) as http:
            await collect(
                LmStudioBackend("http://lmstudio", http),
                request_of(
                    temperature=0.3,
                    top_p=0.9,
                    max_tokens=128,
                    stop=["ENDE"],
                    seed=42,
                    json_mode=True,
                ),
            )

        payload = gesendet[0]
        assert payload["temperature"] == 0.3
        assert payload["top_p"] == 0.9
        assert payload["max_tokens"] == 128
        assert payload["stop"] == ["ENDE"]
        assert payload["seed"] == 42
        assert payload["response_format"] == {"type": "json_object"}

    @pytest.mark.asyncio
    async def test_nicht_gesetzte_parameter_tauchen_nicht_auf(self):
        # Sonst ueberschreibt das Gateway die Voreinstellungen des Backends
        # mit Werten, die niemand angefordert hat.
        gesendet: list = []
        async with httpx.AsyncClient(transport=self._lmstudio(gesendet)) as http:
            await collect(LmStudioBackend("http://lmstudio", http), request_of())

        payload = gesendet[0]
        for feld in ("temperature", "top_p", "max_tokens", "stop", "seed",
                     "response_format", "presence_penalty", "frequency_penalty"):
            assert feld not in payload, f"{feld} haette nicht gesetzt werden duerfen"
