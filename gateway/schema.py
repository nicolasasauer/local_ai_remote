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

from pydantic import BaseModel, Field, field_validator

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
    #: Speicher, den ein Token Kontext im KV-Cache belegt. Damit schaetzt die
    #: App vor dem Laden, was ein groesseres Kontextfenster kostet.
    kv_bytes_per_token: Fact[int] = Field(default_factory=Fact)
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
    #: Ob ``/v1/models/pull`` eingeschaltet ist - die App blendet den
    #: Download sonst aus, statt einen Knopf anzubieten, der nur 403 liefert.
    pull_enabled: bool = False
    #: Obergrenze fuer das Kontextfenster (``GATEWAY_MAX_CONTEXT``), ``None``
    #: heisst: nur die des Modells.
    max_context: Optional[int] = None


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


class ToolCall(BaseModel):
    """Ein Werkzeugaufruf, den das Modell anfordert.

    Das Gateway fuehrt ihn **nicht** aus und interpretiert ihn nicht - es
    kennt weder Namen noch Bedeutung der Werkzeuge. Ausgefuehrt wird auf dem
    Rechner des Clients, der die Werkzeuge angeboten hat.
    """

    id: str
    name: str
    #: JSON-String, unveraendert wie vom Modell erzeugt. Ollama liefert ein
    #: Objekt, LM Studio einen String - hier gilt die OpenAI-Form, damit die
    #: Argumente nicht durch zweimaliges Parsen und Serialisieren laufen.
    arguments: str


class ChatMessage(BaseModel):
    role: str
    content: str
    #: base64-kodierte Bilder, ohne Data-URL-Prefix.
    images: list[str] = Field(default_factory=list)

    #: Bei ``role="assistant"``: die Werkzeuge, die das Modell aufrufen wollte.
    tool_calls: list[ToolCall] = Field(default_factory=list)
    #: Bei ``role="tool"``: auf welchen Aufruf sich das Ergebnis bezieht.
    tool_call_id: Optional[str] = None
    #: Bei ``role="tool"``: Name des Werkzeugs. Ollama ordnet Ergebnisse ueber
    #: den Namen zu, nicht ueber die Id.
    tool_name: Optional[str] = None


class GpuMode(str, Enum):
    #: Backend entscheidet - der Normalfall.
    auto = "auto"
    #: So viel wie moeglich auf die Grafikkarte.
    max = "max"
    #: Nur CPU: langsam, aber passt immer, und die GPU bleibt frei.
    off = "off"


#: Laengste Haltedauer ausser "dauerhaft". Wer laenger will, pinnt.
MAX_KEEP_ALIVE_S = 7 * 24 * 3600


class LoadOptions(BaseModel):
    """Wie ein Modell geladen werden soll.

    Bewusst eine feste, kleine Liste statt durchgereichter Backend-Optionen:
    die App bestimmt, *wie viel* Speicher ein Modell bekommt, aber sie kann
    dem Backend keine beliebigen Schalter setzen.
    """

    #: Kontextfenster in Tokens. ``None``: Vorgabe des Backends.
    context_length: Optional[int] = Field(default=None, ge=512, le=2_000_000)
    #: Sekunden im Speicher nach der letzten Anfrage. ``-1`` dauerhaft,
    #: ``0`` sofort entladen, ``None`` Vorgabe des Backends.
    keep_alive: Optional[int] = None
    gpu: GpuMode = GpuMode.auto

    @field_validator("keep_alive")
    @classmethod
    def _haltedauer(cls, v: Optional[int]) -> Optional[int]:
        if v is None or v == -1 or 0 <= v <= MAX_KEEP_ALIVE_S:
            return v
        raise ValueError(
            f"keep_alive muss -1 (dauerhaft) oder 0..{MAX_KEEP_ALIVE_S} Sekunden sein"
        )

    @property
    def is_default(self) -> bool:
        return (
            self.context_length is None
            and self.keep_alive is None
            and self.gpu is GpuMode.auto
        )


class ChatRequest(BaseModel):
    backend: BackendId
    model: str
    messages: list[ChatMessage]
    temperature: Optional[float] = None
    top_p: Optional[float] = None
    max_tokens: Optional[int] = None
    #: Sequenzen, bei denen die Generierung endet.
    stop: list[str] = Field(default_factory=list)
    seed: Optional[int] = None
    presence_penalty: Optional[float] = None
    frequency_penalty: Optional[float] = None
    #: Antwort als JSON erzwingen (OpenAI: ``response_format``).
    json_mode: bool = False

    #: Werkzeuge, die der Client anbietet. Werden unveraendert an das Backend
    #: durchgereicht; das Gateway prueft sie nicht und ruft sie nicht auf.
    tools: list[dict[str, Any]] = Field(default_factory=list)
    tool_choice: Optional[Any] = None

    #: Recherche einschalten. Das Gateway haengt dann *seinen* Werkzeugkatalog
    #: an - die App kann keine eigenen Werkzeuge vorgeben.
    research: bool = False

    #: Denkschritte anfordern. ``None`` heisst: das Gateway entscheidet anhand
    #: der Faehigkeiten des Modells. Ollama liefert ``thinking`` nur, wenn es
    #: ausdruecklich angefordert wird - ohne das antwortet ein Reasoning-Modell
    #: mit leerem ``content``.
    think: Optional[bool] = None

    #: Ladeoptionen fuer dieses Modell. Nur ueber die App-API erreichbar - die
    #: OpenAI-Oberflaeche fuer Agenten setzt das Feld nie.
    load: Optional[LoadOptions] = None


class ModelRef(BaseModel):
    backend: BackendId
    model: str


class LoadRequest(ModelRef):
    load: LoadOptions = Field(default_factory=LoadOptions)


class PullRequest(BaseModel):
    model: str = Field(min_length=1, max_length=200)


class PullState(str, Enum):
    running = "running"
    done = "done"
    failed = "failed"
    cancelled = "cancelled"


class PullJob(BaseModel):
    """Ein Download, wie ihn die App anzeigt."""

    model: str
    state: PullState
    #: Letzte Statuszeile von Ollama, z. B. "pulling manifest".
    status: str = ""
    completed: int = 0
    #: ``None``, solange Ollama die Groesse noch nicht genannt hat - eine
    #: erfundene Null wuerde als "fertig" gelesen.
    total: Optional[int] = None
    error: Optional[str] = None
    started_at: datetime
    finished_at: Optional[datetime] = None


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
