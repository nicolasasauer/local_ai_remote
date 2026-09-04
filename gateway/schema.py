"""Gemeinsames Schema fuer beide Backends.

Kernidee: Jeder Wert, der je nach Backend oder Version fehlen kann, wird als
``Fact`` uebertragen - mit Wert, Sicherheitsgrad und Begruendung. Die App kann
damit "wissen wir nicht" von "gibt es hier nicht" und von "ist tatsaechlich 0"
unterscheiden, ohne zu raten.
"""

from __future__ import annotations

from datetime import datetime
from enum import Enum
from typing import Any, Generic, Optional, TypeVar

from pydantic import BaseModel, Field

T = TypeVar("T")


class Certainty(str, Enum):
    known = "known"
    #: Wert existiert grundsaetzlich, konnte aber nicht ermittelt werden.
    unknown = "unknown"
    #: Backend liefert diese Information prinzipiell nicht.
    unsupported = "unsupported"


class Fact(BaseModel, Generic[T]):
    value: Optional[T] = None
    certainty: Certainty = Certainty.known
    note: Optional[str] = None

    @classmethod
    def of(cls, value: T) -> "Fact[T]":
        return cls(value=value, certainty=Certainty.known)

    @classmethod
    def unknown_because(cls, note: str) -> "Fact[T]":
        return cls(value=None, certainty=Certainty.unknown, note=note)

    @classmethod
    def unsupported_because(cls, note: str) -> "Fact[T]":
        return cls(value=None, certainty=Certainty.unsupported, note=note)

    @classmethod
    def maybe(cls, value: Optional[T], note: str) -> "Fact[T]":
        """Wert wenn vorhanden, sonst ``unknown`` mit Begruendung."""
        return cls.of(value) if value is not None else cls.unknown_because(note)


class BackendId(str, Enum):
    ollama = "ollama"
    lmstudio = "lmstudio"


class ModelState(str, Enum):
    loaded = "loaded"
    loading = "loading"
    unloading = "unloading"
    not_loaded = "not_loaded"
    error = "error"


class ModelKind(str, Enum):
    llm = "llm"
    vision = "vlm"
    embedding = "embedding"
    unknown = "unknown"


class ModelEntry(BaseModel):
    id: str
    label: str
    backend: BackendId
    state: ModelState
    kind: ModelKind = ModelKind.unknown

    family: Fact[str] = Field(default_factory=Fact)
    parameter_size: Fact[str] = Field(default_factory=Fact)
    quantization: Fact[str] = Field(default_factory=Fact)
    disk_bytes: Fact[int] = Field(default_factory=Fact)

    #: Nur belegt, solange das Modell geladen ist.
    vram_bytes: Fact[int] = Field(default_factory=Fact)
    #: Anteil des Modells, der wirklich auf der GPU liegt (0..1).
    vram_fraction: Fact[float] = Field(default_factory=Fact)

    context_length: Fact[int] = Field(default_factory=Fact)
    loaded_context_length: Fact[int] = Field(default_factory=Fact)
    unloads_at: Fact[datetime] = Field(default_factory=Fact)

    vision: Fact[bool] = Field(default_factory=Fact)
    tools: Fact[bool] = Field(default_factory=Fact)
    #: Modell erzeugt Denkschritte, die getrennt vom Antworttext ankommen.
    thinking: Fact[bool] = Field(default_factory=Fact)

    error: Optional[str] = None


class BackendHealth(BaseModel):
    backend: BackendId
    reachable: bool
    version: Fact[str] = Field(default_factory=Fact)
    message: Optional[str] = None


class GatewayHealth(BaseModel):
    ok: bool = True
    hostname: str
    gateway_version: str
    backends: list[BackendHealth]


class GpuSample(BaseModel):
    name: str
    vendor: str
    source: str
    util_percent: Fact[float] = Field(default_factory=Fact)
    vram_used_bytes: Fact[int] = Field(default_factory=Fact)
    vram_total_bytes: Fact[int] = Field(default_factory=Fact)
    temp_c: Fact[float] = Field(default_factory=Fact)
    power_watts: Fact[float] = Field(default_factory=Fact)


class TelemetrySample(BaseModel):
    at: datetime
    cpu_percent: Fact[float] = Field(default_factory=Fact)
    ram_used_bytes: Fact[int] = Field(default_factory=Fact)
    ram_total_bytes: Fact[int] = Field(default_factory=Fact)
    gpus: list[GpuSample] = Field(default_factory=list)
    #: Gesetzt, wenn ueberhaupt keine GPU ausgelesen werden konnte.
    gpu_note: Optional[str] = None


class ChatMessage(BaseModel):
    role: str
    content: str
    #: base64-kodierte Bilder, ohne Data-URL-Prefix.
    images: list[str] = Field(default_factory=list)


class ChatRequest(BaseModel):
    backend: BackendId
    model: str
    messages: list[ChatMessage]
    temperature: Optional[float] = None
    max_tokens: Optional[int] = None

    #: Denkschritte anfordern. ``None`` heisst: das Gateway entscheidet anhand
    #: der Faehigkeiten des Modells. Ollama liefert ``thinking`` nur, wenn es
    #: ausdruecklich angefordert wird - ohne das antwortet ein Reasoning-Modell
    #: mit leerem ``content``.
    think: Optional[bool] = None


class ModelRef(BaseModel):
    backend: BackendId
    model: str


class ChatMetrics(BaseModel):
    total_ms: Fact[float] = Field(default_factory=Fact)
    load_ms: Fact[float] = Field(default_factory=Fact)
    time_to_first_token_ms: Fact[float] = Field(default_factory=Fact)
    prompt_tokens: Fact[int] = Field(default_factory=Fact)
    completion_tokens: Fact[int] = Field(default_factory=Fact)
    tokens_per_second: Fact[float] = Field(default_factory=Fact)
    stop_reason: Fact[str] = Field(default_factory=Fact)

    #: Das Modell, das laut Backend geantwortet hat. LM Studio beantwortet
    #: jeden Namen mit dem gerade geladenen Modell - auch einen erfundenen,
    #: und mit Status 200. Ohne diese Angabe waere nicht erkennbar, dass eine
    #: Antwort von einem anderen Modell stammt als angefragt.
    served_model: Fact[str] = Field(default_factory=Fact)
