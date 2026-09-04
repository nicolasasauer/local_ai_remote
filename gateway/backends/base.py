"""Gemeinsames Interface fuer Ollama und LM Studio."""

from __future__ import annotations

import abc
from typing import AsyncIterator

import httpx

from ..schema import (
    BackendHealth,
    BackendId,
    ChatMetrics,
    ChatRequest,
    ModelEntry,
)


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

    def _url(self, path: str) -> str:
        return f"{self.base_url}{path}"
