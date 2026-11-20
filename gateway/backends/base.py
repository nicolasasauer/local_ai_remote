"""Gemeinsames Interface fuer Ollama und LM Studio."""

from __future__ import annotations

import abc
import re
from typing import AsyncIterator

import httpx

from ..schema import (
    BackendHealth,
    BackendId,
    ChatMetrics,
    ChatRequest,
    LoadOptions,
    ModelEntry,
    ToolCall,
)

#: Was als Modellname durchgeht. Ollama-Namen (``qwen3:8b``,
#: ``hf.co/user/repo:Q4_K_M``) und LM-Studio-Schluessel
#: (``qwen/qwen3-coder-30b``) passen hinein; ein fuehrender Bindestrich nicht.
_MODELLNAME = re.compile(r"^[A-Za-z0-9][A-Za-z0-9._:/@+-]{0,199}$")


def check_model_name(name: str) -> str:
    """Weist Namen ab, die kein Modellname sein koennen.

    Wichtig, wo der Name an ein Kommandozeilenwerkzeug geht: ``lms unload
    --all`` waere kein Modell, sondern ein Schalter. Die Liste wird ohne
    Shell uebergeben, aber ein Argument, das mit ``-`` beginnt, liest jedes
    Werkzeug als Option.
    """
    if not _MODELLNAME.match(name) or ".." in name:
        raise BackendError(f"Ungueltiger Modellname: {name!r}", status_code=400)
    return name


class BackendError(Exception):
    """Fehler, der dem Client als Grund angezeigt werden darf."""

    def __init__(self, message: str, *, status_code: int = 502) -> None:
        super().__init__(message)
        self.message = message
        self.status_code = status_code


class NotSupported(BackendError):
    def __init__(self, message: str) -> None:
        super().__init__(message, status_code=501)


class ChatEvent:
    """Basisklasse der Stream-Events."""


class Delta(ChatEvent):
    def __init__(self, text: str) -> None:
        self.text = text


class Reasoning(ChatEvent):
    """Denkschritte eines Reasoning-Modells.

    Bewusst getrennt von ``Delta``: der Text gehoert nicht in die Antwort und
    nicht in den Kontext des naechsten Zuges, aber er ist der einzige Beleg,
    dass das Modell arbeitet - bei kurzem Limit ist er sogar die *einzige*
    Ausgabe. Ihn zu verwerfen erzeugt eine leere Antwort ohne Begruendung.
    """

    def __init__(self, text: str) -> None:
        self.text = text


class ToolCalls(ChatEvent):
    """Das Modell moechte Werkzeuge aufrufen.

    Kommt vollstaendig, nie stueckweise: Ollama liefert die Aufrufe in einem
    Zug, bei LM Studio setzt der Adapter die Fragmente vorher zusammen. Ein
    halber Aufruf waere fuer den Client wertlos - er kann ihn nicht ausfuehren
    und nicht anzeigen.
    """

    def __init__(self, calls: list[ToolCall]) -> None:
        self.calls = calls


class Status(ChatEvent):
    def __init__(self, state: str, note: str | None = None) -> None:
        self.state = state
        self.note = note


class Done(ChatEvent):
    def __init__(self, metrics: ChatMetrics) -> None:
        self.metrics = metrics


class Failure(ChatEvent):
    def __init__(self, message: str) -> None:
        self.message = message


class Backend(abc.ABC):
    id: BackendId

    def check_chat_load(self, opts: LoadOptions) -> None:
        """Wirft, wenn dieses Backend eine Ladeoption pro Anfrage nicht
        umsetzen kann. Abgelehnt statt still ignoriert: sonst antwortet ein
        Modell mit anderem Kontextfenster als eingestellt, und niemand sieht es.
        """

    def __init__(self, base_url: str, client: httpx.AsyncClient) -> None:
        self.base_url = base_url
        self.http = client

    @abc.abstractmethod
    async def health(self) -> BackendHealth: ...

    @abc.abstractmethod
    async def list_models(self) -> list[ModelEntry]: ...

    @abc.abstractmethod
    async def stream_chat(self, req: ChatRequest) -> AsyncIterator[ChatEvent]: ...

    @abc.abstractmethod
    async def set_keep_alive(self, model: str, *, pin: bool) -> None:
        """``pin=True`` haelt das Modell im Speicher, ``False`` entlaedt es."""

    async def load(self, model: str, opts: LoadOptions) -> None:
        """Laedt das Modell jetzt, mit diesen Optionen.

        Kehrt erst zurueck, wenn das Modell im Speicher ist - das kann bei
        grossen Modellen Minuten dauern.
        """
        raise NotSupported("Dieses Backend kann Modelle nicht gezielt laden")

    def _url(self, path: str) -> str:
        return f"{self.base_url}{path}"
