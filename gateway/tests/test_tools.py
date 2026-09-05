"""Werkzeugaufrufe auf Adapter-Ebene.

Die beiden Backends liefern sie in unvereinbarer Form:

* **Ollama** schickt den Aufruf vollstaendig in einem Chunk, mit eigener Id,
  und ``arguments`` als Objekt. Als Abschlussgrund meldet es ``stop``.
* **LM Studio** schickt Fragmente - erst Id und Name, dann die Argumente
  stueckweise ueber mehrere Chunks - und meldet ``tool_calls``.

Beides muss beim Client als *ein* vollstaendiger Aufruf im OpenAI-Format
ankommen. Ein halber Aufruf ist wertlos: der Client kann ihn weder ausfuehren
noch anzeigen.
"""

from __future__ import annotations

import json

import httpx
import pytest

from gateway.backends.base import Done, ToolCalls
from gateway.backends.lmstudio import LmStudioBackend
from gateway.backends.ollama import OllamaBackend
from gateway.schema import BackendId, ChatMessage, ChatRequest, ToolCall

from .test_backends import TroepfelStream, collect, ndjson, request_of

WERKZEUG = {
    "type": "function",
    "function": {"name": "wetter", "parameters": {"type": "object"}},
}


class TestOllama:
    def _transport(self, gesendet: list, *, mit_aufruf: bool):
        def handler(request: httpx.Request) -> httpx.Response:
            if request.url.path == "/api/show":
                return httpx.Response(200, json={"capabilities": ["tools"]})
            gesendet.append(json.loads(request.content))
            nachricht: dict = {"role": "assistant", "content": ""}
            if mit_aufruf:
                nachricht["tool_calls"] = [
                    {
                        "id": "abc123",
                        "function": {
                            "index": 0,
                            "name": "wetter",
                            "arguments": {"stadt": "Berlin"},
                        },
                    }
                ]
            return httpx.Response(
                200,
                content=ndjson(
                    {"message": nachricht, "done": True, "done_reason": "stop"}
                ),
            )

        return httpx.MockTransport(handler)

    @pytest.mark.asyncio
    async def test_werkzeuge_gehen_unveraendert_raus(self):
        gesendet: list = []
        async with httpx.AsyncClient(
            transport=self._transport(gesendet, mit_aufruf=False)
        ) as http:
            await collect(
                OllamaBackend("http://ollama", http),
                request_of(tools=[WERKZEUG], tool_choice="auto"),
            )

        assert gesendet[0]["tools"] == [WERKZEUG]
        assert gesendet[0]["tool_choice"] == "auto"

    @pytest.mark.asyncio
    async def test_argumente_werden_zum_json_string(self):
        # Ollama liefert ein Objekt, OpenAI-Clients erwarten einen String.
        async with httpx.AsyncClient(
            transport=self._transport([], mit_aufruf=True)
        ) as http:
            events = await collect(
                OllamaBackend("http://ollama", http), request_of(tools=[WERKZEUG])
            )

        aufruf = next(e for e in events if isinstance(e, ToolCalls)).calls[0]
        assert aufruf.id == "abc123"
        assert aufruf.name == "wetter"
        assert isinstance(aufruf.arguments, str)
        assert json.loads(aufruf.arguments) == {"stadt": "Berlin"}

    @pytest.mark.asyncio
    async def test_stop_reason_wird_zu_tool_calls(self):
        # Ollama meldet "stop", auch wenn Werkzeuge aufgerufen wurden. Clients
        # entscheiden aber genau daran, ob sie ausfuehren muessen.
        async with httpx.AsyncClient(
            transport=self._transport([], mit_aufruf=True)
        ) as http:
            events = await collect(
                OllamaBackend("http://ollama", http), request_of(tools=[WERKZEUG])
            )

        done = next(e for e in events if isinstance(e, Done))
        assert done.metrics.stop_reason.value == "tool_calls"

    @pytest.mark.asyncio
    async def test_ohne_aufruf_bleibt_der_grund_wie_gemeldet(self):
        async with httpx.AsyncClient(
            transport=self._transport([], mit_aufruf=False)
        ) as http:
            events = await collect(OllamaBackend("http://ollama", http), request_of())

        done = next(e for e in events if isinstance(e, Done))
        assert done.metrics.stop_reason.value == "stop"
        assert not [e for e in events if isinstance(e, ToolCalls)]

    @pytest.mark.asyncio
    async def test_verlauf_geht_in_ollamas_form_zurueck(self):
        gesendet: list = []
        async with httpx.AsyncClient(
            transport=self._transport(gesendet, mit_aufruf=False)
        ) as http:
            req = ChatRequest(
                backend=BackendId.ollama,
                model="m",
                messages=[
                    ChatMessage(role="user", content="Wetter?"),
                    ChatMessage(
                        role="assistant",
                        content="",
                        tool_calls=[
                            ToolCall(
                                id="abc123",
                                name="wetter",
                                arguments='{"stadt": "Berlin"}',
                            )
                        ],
                    ),
                    ChatMessage(
                        role="tool",
                        content="12 Grad",
                        tool_call_id="abc123",
                        tool_name="wetter",
                    ),
                ],
            )
            await collect(OllamaBackend("http://ollama", http), req)

        nachrichten = gesendet[0]["messages"]
        # Argumente muessen als Objekt zurueck, nicht als String.
        assert nachrichten[1]["tool_calls"][0]["function"]["arguments"] == {
            "stadt": "Berlin"
        }
        assert nachrichten[2]["role"] == "tool"
        # Ollama ordnet Ergebnisse ueber den Namen zu, nicht ueber die Id.
        assert nachrichten[2]["tool_name"] == "wetter"


class TestLmStudio:
    def _transport(self, gesendet: list, fragmente: list):
        def handler(request: httpx.Request) -> httpx.Response:
            gesendet.append(json.loads(request.content))
            chunks = [
                {"choices": [{"delta": {"tool_calls": [f]}}]} for f in fragmente
            ]
            chunks.append({"choices": [{"delta": {}, "finish_reason": "tool_calls"}]})
            return httpx.Response(
                200,
                headers={"content-type": "text/event-stream"},
                stream=TroepfelStream(chunks),
            )

        return httpx.MockTransport(handler)

    @pytest.mark.asyncio
    async def test_fragmente_werden_zusammengesetzt(self):
        # Ohne Zusammensetzen bekaeme der Client abgeschnittenes JSON.
        fragmente = [
            {
                "index": 0,
                "id": "call_x",
                "type": "function",
                "function": {"name": "wetter", "arguments": ""},
            },
            {"index": 0, "function": {"arguments": '{"stadt":'}},
            {"index": 0, "function": {"arguments": '"Berlin"}'}},
        ]
        async with httpx.AsyncClient(transport=self._transport([], fragmente)) as http:
            events = await collect(
                LmStudioBackend("http://lmstudio", http), request_of(tools=[WERKZEUG])
            )

        aufrufe = next(e for e in events if isinstance(e, ToolCalls)).calls
        assert len(aufrufe) == 1
        assert aufrufe[0].id == "call_x"
        assert aufrufe[0].name == "wetter"
        assert json.loads(aufrufe[0].arguments) == {"stadt": "Berlin"}

    @pytest.mark.asyncio
    async def test_mehrere_aufrufe_bleiben_getrennt(self):
        fragmente = [
            {"index": 0, "id": "a", "function": {"name": "eins", "arguments": "{}"}},
            {
                "index": 1,
                "id": "b",
                "function": {"name": "zwei", "arguments": '{"x":'},
            },
            {"index": 1, "function": {"arguments": "1}"}},
        ]
        async with httpx.AsyncClient(transport=self._transport([], fragmente)) as http:
            events = await collect(
                LmStudioBackend("http://lmstudio", http), request_of(tools=[WERKZEUG])
            )

        aufrufe = next(e for e in events if isinstance(e, ToolCalls)).calls
        assert [a.name for a in aufrufe] == ["eins", "zwei"]
        assert json.loads(aufrufe[1].arguments) == {"x": 1}

    @pytest.mark.asyncio
    async def test_verlauf_geht_im_openai_format_zurueck(self):
        gesendet: list = []
        async with httpx.AsyncClient(transport=self._transport(gesendet, [])) as http:
            req = ChatRequest(
                backend=BackendId.lmstudio,
                model="m",
                messages=[
                    ChatMessage(
                        role="assistant",
                        content="",
                        tool_calls=[
                            ToolCall(
                                id="call_x",
                                name="wetter",
                                arguments='{"stadt": "Berlin"}',
                            )
                        ],
                    ),
                    ChatMessage(
                        role="tool",
                        content="12 Grad",
                        tool_call_id="call_x",
                        tool_name="wetter",
                    ),
                ],
            )
            await collect(LmStudioBackend("http://lmstudio", http), req)

        nachrichten = gesendet[0]["messages"]
        # Hier bleiben die Argumente ein String.
        assert nachrichten[0]["tool_calls"][0]["function"]["arguments"] == (
            '{"stadt": "Berlin"}'
        )
        assert nachrichten[1] == {
            "role": "tool",
            "content": "12 Grad",
            "tool_call_id": "call_x",
        }
