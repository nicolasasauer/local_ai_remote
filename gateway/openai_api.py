"""OpenAI-kompatible Oberflaeche fuer Agenten-Werkzeuge.

Warum ein zweiter Satz Routen statt einer Erweiterung von ``/v1``:

Die Routen unter ``/v1`` gehoeren der App und tragen ``Fact``-Objekte, die es
bei OpenAI nicht gibt - ``/v1/models`` waere in beiden Welten derselbe Pfad mit
unvereinbarem Inhalt. Diese Oberflaeche liegt deshalb unter ``/openai/v1`` und
uebersetzt in beide Richtungen, statt die App-API zu verbiegen.

Sie ist **standardmaessig aus**. Eine Schnittstelle, an die man Werkzeuge
haengt, die Befehle auf dem eigenen Rechner ausfuehren, soll nicht
stillschweigend auftauchen, nur weil jemand das Gateway aktualisiert.
"""

from __future__ import annotations

import json
import secrets
import time
import uuid
from typing import Any, AsyncIterator, Literal, Optional, Union

from fastapi import APIRouter, Depends, Header, HTTPException, Request
from fastapi.responses import JSONResponse, StreamingResponse
from pydantic import BaseModel, ConfigDict, Field

from .backends.base import (
    Backend,
    BackendError,
    Delta,
    Done,
    Failure,
    Reasoning,
    ToolCalls,
)
from .config import CONFIG
from .schema import BackendId, ChatMessage, ChatRequest, ModelEntry, ToolCall

router = APIRouter(prefix="/openai/v1", tags=["openai"])


# --------------------------------------------------------------------------
# Auth
# --------------------------------------------------------------------------


def require_agent_token(authorization: str | None = Header(default=None)) -> None:
    """Eigenes Token, nicht das der App.

    Agenten-Werkzeuge legen ihren Schluessel im Klartext ab - in
    ``~/.codex/config.toml``, in Umgebungsvariablen, in Shell-Historien. Mit
    einem getrennten Token laesst sich genau dieser Zugang zurueckziehen, ohne
    das Telefon neu einrichten zu muessen.
    """
    if not CONFIG.agent_token:
        # Nicht 401: ohne gesetztes Token gibt es diese Oberflaeche schlicht
        # nicht, und ein 404 verraet weniger ueber das, was hier laeuft.
        raise HTTPException(status_code=404, detail="Not Found")

    expected = f"Bearer {CONFIG.agent_token}"
    if not secrets.compare_digest(authorization or "", expected):
        raise _error(401, "Ungueltiger API-Schluessel", "invalid_request_error")


def _error(status: int, message: str, kind: str = "invalid_request_error") -> HTTPException:
    """Fehler im OpenAI-Format - Clients lesen `error.message` aus."""
    return HTTPException(
        status_code=status,
        detail={"error": {"message": message, "type": kind, "code": None}},
    )


# --------------------------------------------------------------------------
# Schema
# --------------------------------------------------------------------------


class _Lenient(BaseModel):
    # Clients schicken Felder mit, die dieses Gateway nicht kennt
    # (`presence_penalty`, `logit_bias`, `user`, ...). Ein 422 dafuer waere
    # unbrauchbar - unbekannte Felder werden verworfen.
    model_config = ConfigDict(extra="ignore")


class OpenAIMessage(_Lenient):
    role: str
    #: Entweder ein String oder die Teile-Liste aus dem Vision-Format.
    content: Union[str, list[dict[str, Any]], None] = None
    name: Optional[str] = None

    #: Bei ``role="assistant"``: was das Modell im vorigen Zug aufrufen wollte.
    tool_calls: Optional[list[dict[str, Any]]] = None
    #: Bei ``role="tool"``: auf welchen Aufruf sich das Ergebnis bezieht.
    tool_call_id: Optional[str] = None


class StreamOptions(_Lenient):
    include_usage: bool = False


class ChatCompletionRequest(_Lenient):
    model: str
    messages: list[OpenAIMessage]
    stream: bool = False

    temperature: Optional[float] = None
    top_p: Optional[float] = None
    max_tokens: Optional[int] = None
    #: Neuerer Name fuer dasselbe; manche Clients schicken nur noch den.
    max_completion_tokens: Optional[int] = None
    stop: Union[str, list[str], None] = None
    seed: Optional[int] = None
    presence_penalty: Optional[float] = None
    frequency_penalty: Optional[float] = None
    response_format: Optional[dict[str, Any]] = None
    stream_options: Optional[StreamOptions] = None

    #: Wird nicht erfuellt, sondern abgelehnt - siehe `pruefe_machbarkeit`.
    n: Optional[int] = None
    tools: Optional[list[dict[str, Any]]] = None
    tool_choice: Union[str, dict[str, Any], None] = None
    logprobs: Optional[bool] = None

    def limit(self) -> Optional[int]:
        return self.max_completion_tokens or self.max_tokens

    def stop_list(self) -> list[str]:
        if self.stop is None:
            return []
        return [self.stop] if isinstance(self.stop, str) else list(self.stop)

    def json_mode(self) -> bool:
        return (self.response_format or {}).get("type") in (
            "json_object",
            "json_schema",
        )

    def pruefe_machbarkeit(self) -> None:
        """Lieber ein klarer Fehler als eine Antwort, die anders zustande kam.

        Ein still verworfener Parameter erzeugt ein Ergebnis, das niemand
        erklaeren kann. Ein 400 mit Begruendung kostet eine Sekunde.
        """
        if self.n is not None and self.n != 1:
            raise _error(
                400,
                f"n={self.n} wird nicht unterstuetzt; es kommt immer genau eine "
                "Antwort zurueck.",
                "unsupported_parameter",
            )
        if self.logprobs:
            raise _error(
                400,
                "logprobs werden von den Backends nicht durchgereicht.",
                "unsupported_parameter",
            )
        if (self.response_format or {}).get("type") == "json_schema":
            raise _error(
                400,
                "response_format 'json_schema' wird nicht unterstuetzt; "
                "'json_object' geht.",
                "unsupported_parameter",
            )


class ModelCard(BaseModel):
    id: str
    object: Literal["model"] = "model"
    created: int
    owned_by: str


class ModelList(BaseModel):
    object: Literal["list"] = "list"
    data: list[ModelCard] = Field(default_factory=list)


# --------------------------------------------------------------------------
# Umschluesselung der Modellnamen
# --------------------------------------------------------------------------

#: OpenAI kennt einen flachen Namensraum, hier gibt es zwei Backends mit
#: teils gleichen Modellen. Der Praefix macht die Wahl eindeutig.
def qualified(entry: ModelEntry) -> str:
    return f"{entry.backend.value}/{entry.id}"


def split_qualified(name: str) -> tuple[Optional[BackendId], str]:
    head, _, rest = name.partition("/")
    for backend in BackendId:
        if head == backend.value and rest:
            return backend, rest
    return None, name


async def resolve(
    name: str, backends: dict[BackendId, Backend]
) -> tuple[BackendId, str]:
    """Findet Backend und Modell-Id zu einem angefragten Namen.

    Der Praefix ist der verlaessliche Weg. Ein blanker Name wird trotzdem
    aufgeloest, solange er eindeutig ist - sonst muesste man in jedem Werkzeug
    die Schreibweise nachschlagen.
    """
    backend, model = split_qualified(name)
    if backend is not None:
        return backend, model

    treffer: list[tuple[BackendId, str]] = []
    for backend_id, adapter in backends.items():
        try:
            entries = await adapter.list_models()
        except Exception:  # noqa: BLE001 - ein totes Backend darf nicht stoeren
            continue
        for entry in entries:
            if entry.id == name:
                treffer.append((backend_id, entry.id))

    if not treffer:
        raise _error(
            404,
            f"Modell '{name}' ist auf keinem Backend vorhanden. "
            "Eindeutig wird es mit Praefix: 'ollama/<id>' oder 'lmstudio/<id>'.",
            "model_not_found",
        )
    if len(treffer) > 1:
        orte = ", ".join(f"{b.value}/{m}" for b, m in treffer)
        raise _error(
            400,
            f"Modell '{name}' gibt es auf mehreren Backends ({orte}). "
            "Bitte mit Praefix angeben.",
        )
    return treffer[0]


# --------------------------------------------------------------------------
# Umschluesselung der Nachrichten
# --------------------------------------------------------------------------


def to_internal(messages: list[OpenAIMessage]) -> list[ChatMessage]:
    out: list[ChatMessage] = []
    for msg in messages:
        text_parts: list[str] = []
        images: list[str] = []

        if isinstance(msg.content, str):
            text_parts.append(msg.content)
        elif isinstance(msg.content, list):
            for part in msg.content:
                kind = part.get("type")
                if kind == "text":
                    text_parts.append(str(part.get("text", "")))
                elif kind == "image_url":
                    url = (part.get("image_url") or {}).get("url", "")
                    # Nur eingebettete Bilder: eine fremde URL wuerde das
                    # Gateway zu einem Downloader machen, der Adressen aus dem
                    # Nachrichteninhalt abruft.
                    if url.startswith("data:"):
                        images.append(url.split(",", 1)[-1])

        # Werkzeugaufrufe und -ergebnisse gehen unveraendert durch. Das
        # Gateway prueft die Argumente nicht und fuehrt nichts aus - sie sind
        # Modellausgabe und damit Sache des Clients, der sie ausfuehrt.
        aufrufe: list[ToolCall] = []
        for roh in msg.tool_calls or []:
            funktion = roh.get("function") or {}
            if not funktion.get("name"):
                continue
            aufrufe.append(
                ToolCall(
                    id=str(roh.get("id") or f"call_{len(aufrufe)}"),
                    name=str(funktion["name"]),
                    arguments=str(funktion.get("arguments") or "{}"),
                )
            )

        out.append(
            ChatMessage(
                role=msg.role,
                content="\n\n".join(p for p in text_parts if p),
                images=images,
                tool_calls=aufrufe,
                tool_call_id=msg.tool_call_id,
                # Ollama ordnet Ergebnisse ueber den Namen zu. OpenAI schickt
                # ihn nur in `name` - ohne das findet Ollama den Bezug nicht.
                tool_name=msg.name if msg.role == "tool" else None,
            )
        )
    return out


def _now() -> int:
    return int(time.time())


def _completion_id() -> str:
    return f"chatcmpl-{uuid.uuid4().hex[:24]}"


# --------------------------------------------------------------------------
# Routen
# --------------------------------------------------------------------------


@router.get("/models", response_model=ModelList)
async def list_models(request: Request, _: None = Depends(require_agent_token)) -> ModelList:
    backends: dict[BackendId, Backend] = request.app.state.backends
    created = _now()

    cards: list[ModelCard] = []
    for backend_id, adapter in backends.items():
        try:
            entries = await adapter.list_models()
        except Exception:  # noqa: BLE001 - ein totes Backend leert die Liste nicht
            continue
        cards.extend(
            ModelCard(id=qualified(e), created=created, owned_by=backend_id.value)
            for e in entries
        )
    return ModelList(data=cards)


@router.post("/chat/completions")
async def chat_completions(
    body: ChatCompletionRequest,
    request: Request,
    _: None = Depends(require_agent_token),
):
    body.pruefe_machbarkeit()

    backends: dict[BackendId, Backend] = request.app.state.backends
    backend_id, model = await resolve(body.model, backends)
    adapter = backends[backend_id]

    internal = ChatRequest(
        backend=backend_id,
        model=model,
        messages=to_internal(body.messages),
        temperature=body.temperature,
        top_p=body.top_p,
        max_tokens=body.limit(),
        stop=body.stop_list(),
        seed=body.seed,
        presence_penalty=body.presence_penalty,
        frequency_penalty=body.frequency_penalty,
        json_mode=body.json_mode(),
        tools=body.tools or [],
        tool_choice=body.tool_choice,
    )

    if body.stream:
        include_usage = bool(body.stream_options and body.stream_options.include_usage)
        return StreamingResponse(
            _stream(adapter, internal, body.model, include_usage),
            media_type="text/event-stream",
            headers={"Cache-Control": "no-cache", "X-Accel-Buffering": "no"},
        )
    return await _collect(adapter, internal, body.model)


async def _collect(backend: Backend, req: ChatRequest, label: str) -> JSONResponse:
    """Nicht-streamende Variante: sammeln und in einem Stueck ausliefern."""
    content: list[str] = []
    reasoning: list[str] = []
    aufrufe: list[ToolCall] = []
    usage: dict[str, int] = {}
    finish = "stop"
    served = label

    try:
        async for event in backend.stream_chat(req):
            if isinstance(event, Delta):
                content.append(event.text)
            elif isinstance(event, Reasoning):
                reasoning.append(event.text)
            elif isinstance(event, ToolCalls):
                aufrufe.extend(event.calls)
            elif isinstance(event, Done):
                usage = _usage(event)
                finish = _finish_reason(event)
                served = _served(event, label)
            elif isinstance(event, Failure):
                raise _error(502, event.message, "upstream_error")
    except BackendError as exc:
        raise _error(exc.status_code, exc.message, "upstream_error") from exc

    message: dict[str, Any] = {"role": "assistant", "content": "".join(content)}
    if reasoning:
        message["reasoning_content"] = "".join(reasoning)
    if aufrufe:
        message["tool_calls"] = [_als_openai(c) for c in aufrufe]
        # OpenAI-Clients entscheiden hieran, ob sie Werkzeuge ausfuehren.
        # `content` ist dann ueblicherweise null, nicht der leere String.
        message["content"] = message["content"] or None
        finish = "tool_calls"

    return JSONResponse(
        {
            "id": _completion_id(),
            "object": "chat.completion",
            "created": _now(),
            "model": served,
            "choices": [{"index": 0, "message": message, "finish_reason": finish}],
            "usage": usage,
        }
    )


async def _stream(
    backend: Backend,
    req: ChatRequest,
    label: str,
    include_usage: bool,
) -> AsyncIterator[str]:
    completion_id = _completion_id()
    created = _now()

    served = label

    def chunk(delta: dict[str, Any], finish: str | None = None) -> str:
        payload = {
            "id": completion_id,
            "object": "chat.completion.chunk",
            "created": created,
            "model": served,
            "choices": [{"index": 0, "delta": delta, "finish_reason": finish}],
        }
        return f"data: {json.dumps(payload, ensure_ascii=False)}\n\n"

    yield chunk({"role": "assistant"})

    usage: dict[str, int] = {}
    finish = "stop"
    hatte_aufrufe = False
    try:
        async for event in backend.stream_chat(req):
            if isinstance(event, Delta):
                yield chunk({"content": event.text})
            elif isinstance(event, Reasoning):
                # De-facto-Standard fuer Denkschritte im OpenAI-Format. Wer
                # das Feld nicht kennt, ignoriert es - und bekommt dann eben
                # nur die Antwort, nicht den Denkweg im Antworttext.
                yield chunk({"reasoning_content": event.text})
            elif isinstance(event, ToolCalls):
                # Erst hier vollstaendig: bei LM Studio hat der Adapter die
                # Fragmente zusammengesetzt, bei Ollama kamen sie in einem Zug.
                # Als ein Delta ausgeliefert, wie Clients es erwarten.
                hatte_aufrufe = True
                yield chunk(
                    {
                        "tool_calls": [
                            {"index": i, **_als_openai(c)}
                            for i, c in enumerate(event.calls)
                        ]
                    }
                )
            elif isinstance(event, Done):
                usage = _usage(event)
                finish = _finish_reason(event)
                served = _served(event, label)
            elif isinstance(event, Failure):
                # Der Stream steht schon, ein HTTP-Status geht nicht mehr.
                # Ein Fehlerobjekt ist besser als ein stiller Abbruch, den der
                # Client als leere Antwort deutet.
                yield (
                    "data: "
                    + json.dumps(
                        {"error": {"message": event.message, "type": "upstream_error"}},
                        ensure_ascii=False,
                    )
                    + "\n\n"
                )
                yield "data: [DONE]\n\n"
                return
    except Exception as exc:  # noqa: BLE001
        yield (
            "data: "
            + json.dumps(
                {"error": {"message": f"Gateway-Fehler: {exc}", "type": "server_error"}},
                ensure_ascii=False,
            )
            + "\n\n"
        )
        yield "data: [DONE]\n\n"
        return

    yield chunk({}, "tool_calls" if hatte_aufrufe else finish)
    if include_usage and usage:
        yield (
            "data: "
            + json.dumps(
                {
                    "id": completion_id,
                    "object": "chat.completion.chunk",
                    "created": created,
                    "model": label,
                    "choices": [],
                    "usage": usage,
                },
                ensure_ascii=False,
            )
            + "\n\n"
        )
    yield "data: [DONE]\n\n"


def _als_openai(call: ToolCall) -> dict[str, Any]:
    return {
        "id": call.id,
        "type": "function",
        "function": {"name": call.name, "arguments": call.arguments},
    }


def _served(event: Done, label: str) -> str:
    """Welches Modell tatsaechlich geantwortet hat.

    LM Studio beantwortet jeden Namen mit dem gerade geladenen Modell. Den
    angefragten Namen zurueckzugeben waere eine Behauptung; die OpenAI-API
    selbst liefert hier ebenfalls das konkret verwendete Modell.
    """
    tatsaechlich = event.metrics.served_model.value
    if not tatsaechlich:
        return label
    backend, _ = split_qualified(label)
    return f"{backend.value}/{tatsaechlich}" if backend else tatsaechlich


def _usage(event: Done) -> dict[str, int]:
    """``Fact`` kennt "unbekannt", ``usage`` nicht. Fehlende Zahlen bleiben
    deshalb weg, statt als 0 aufzutauchen - eine 0 waere hier eine Behauptung."""
    prompt = event.metrics.prompt_tokens.value
    completion = event.metrics.completion_tokens.value
    if prompt is None and completion is None:
        return {}
    out: dict[str, int] = {}
    if prompt is not None:
        out["prompt_tokens"] = prompt
    if completion is not None:
        out["completion_tokens"] = completion
    if prompt is not None and completion is not None:
        out["total_tokens"] = prompt + completion
    return out


def _finish_reason(event: Done) -> str:
    raw = event.metrics.stop_reason.value
    # Ollama sagt "length", LM Studio "length"; alles andere gilt als sauberer
    # Abschluss.
    return "length" if raw == "length" else "stop"
