"""LM-Studio-Adapter ueber die REST-Beta ``/api/v0``.

Die Route liefert installierte und geladene Modelle in einem Rutsch, dafuer
fehlen einige Angaben, die Ollama hat - die werden bewusst als ``unsupported``
markiert statt geschaetzt.
"""

from __future__ import annotations

import asyncio
import json
import shutil
import subprocess
import time
from typing import Any, AsyncIterator

import httpx

from ..schema import (
    BackendHealth,
    BackendId,
    ChatMetrics,
    ChatRequest,
    Fact,
    ModelEntry,
    ModelKind,
    ModelState,
)
from .base import (
    Backend,
    BackendError,
    ChatEvent,
    Delta,
    Done,
    Failure,
    NotSupported,
    Reasoning,
    Status,
)

_NO_DISK_SIZE = "LM Studio liefert keine Dateigroesse ueber /api/v0/models"
_NO_VRAM = "LM Studio weist geladenen Modellen keinen VRAM-Wert zu"
_NO_TTL = "LM Studio gibt den Auto-Unload-Timer nicht ueber die API heraus"


class LmStudioBackend(Backend):
    id = BackendId.lmstudio

    async def health(self) -> BackendHealth:
        try:
            res = await self.http.get(self._url("/api/v0/models"), timeout=5)
            res.raise_for_status()
            return BackendHealth(
                backend=self.id,
                reachable=True,
                version=Fact.unsupported_because(
                    "LM Studio veroeffentlicht keine Version ueber die REST-API"
                ),
            )
        except Exception as exc:  # noqa: BLE001
            return BackendHealth(
                backend=self.id,
                reachable=False,
                version=Fact.unknown_because("Backend nicht erreichbar"),
                message=str(exc),
            )

    async def list_models(self) -> list[ModelEntry]:
        try:
            res = await self.http.get(self._url("/api/v0/models"), timeout=15)
            res.raise_for_status()
            data = res.json()
        except Exception as exc:  # noqa: BLE001
            raise BackendError(f"/api/v0/models fehlgeschlagen: {exc}") from exc

        return [self._to_entry(raw) for raw in data.get("data", [])]

    def _to_entry(self, raw: dict[str, Any]) -> ModelEntry:
        model_id = raw.get("id", "?")
        raw_type = (raw.get("type") or "").lower()

        kind = {
            "llm": ModelKind.llm,
            "vlm": ModelKind.vision,
            "embeddings": ModelKind.embedding,
            "embedding": ModelKind.embedding,
        }.get(raw_type, ModelKind.unknown)

        if kind is ModelKind.unknown:
            vision = Fact[bool].unknown_because(
                f"unbekannter Modelltyp '{raw_type or 'leer'}'"
            )
        else:
            vision = Fact.of(kind is ModelKind.vision)

        state_raw = (raw.get("state") or "").lower()
        state = {
            "loaded": ModelState.loaded,
            "loading": ModelState.loading,
            "not-loaded": ModelState.not_loaded,
        }.get(state_raw, ModelState.not_loaded)

        loaded_ctx = raw.get("loaded_context_length")
        return ModelEntry(
            id=model_id,
            label=model_id.split("/")[-1],
            backend=self.id,
            state=state,
            kind=kind,
            family=Fact.maybe(raw.get("arch"), "arch fehlt im Model-Objekt"),
            parameter_size=Fact.unknown_because(
                "Parameterzahl steht nicht im Model-Objekt, nur im Modellnamen"
            ),
            quantization=Fact.maybe(
                raw.get("quantization"), "quantization fehlt im Model-Objekt"
            ),
            disk_bytes=Fact.unsupported_because(_NO_DISK_SIZE),
            vram_bytes=Fact.unsupported_because(_NO_VRAM),
            vram_fraction=Fact.unsupported_because(_NO_VRAM),
            context_length=Fact.maybe(
                raw.get("max_context_length"), "max_context_length fehlt"
            ),
            loaded_context_length=(
                Fact.of(loaded_ctx)
                if loaded_ctx
                else Fact.unsupported_because("Modell ist nicht geladen")
            ),
            unloads_at=Fact.unsupported_because(_NO_TTL),
            vision=vision,
            tools=Fact.unknown_because(
                "LM Studio kennzeichnet Tool-Unterstuetzung nicht pro Modell"
            ),
        )

    async def stream_chat(self, req: ChatRequest) -> AsyncIterator[ChatEvent]:
        payload: dict[str, Any] = {
            "model": req.model,
            "messages": [self._message(m) for m in req.messages],
            "stream": True,
            # Ohne das schickt LM Studio im Stream ueberhaupt kein `usage`.
            # Die Tokenzahlen blieben dann dauerhaft unbekannt - und damit
            # auch die Kalibrierung der Kontextanzeige in der App.
            "stream_options": {"include_usage": True},
        }
        if req.temperature is not None:
            payload["temperature"] = req.temperature
        if req.top_p is not None:
            payload["top_p"] = req.top_p
        if req.max_tokens is not None:
            payload["max_tokens"] = req.max_tokens
        if req.stop:
            payload["stop"] = req.stop
        if req.seed is not None:
            payload["seed"] = req.seed
        if req.presence_penalty is not None:
            payload["presence_penalty"] = req.presence_penalty
        if req.frequency_penalty is not None:
            payload["frequency_penalty"] = req.frequency_penalty
        if req.json_mode:
            payload["response_format"] = {"type": "json_object"}

        started = time.perf_counter()
        first_token_at: float | None = None
        stats: dict[str, Any] = {}
        usage: dict[str, Any] = {}
        finish_reason: str | None = None
        served: str | None = None
        abweichung_gemeldet = False

        try:
            # /api/v0 statt /v1: identisches Format, liefert aber zusaetzlich
            # Statistiken im letzten Chunk.
            async with self.http.stream(
                "POST", self._url("/api/v0/chat/completions"), json=payload
            ) as res:
                if res.status_code != 200:
                    body = (await res.aread()).decode(errors="replace")
                    yield Failure(
                        f"LM Studio antwortete {res.status_code}: {body[:400]}"
                    )
                    return

                async for line in res.aiter_lines():
                    if not line.startswith("data:"):
                        continue
                    raw = line[5:].strip()
                    if not raw or raw == "[DONE]":
                        continue
                    try:
                        chunk = json.loads(raw)
                    except json.JSONDecodeError:
                        continue

                    stats = chunk.get("stats") or stats
                    usage = chunk.get("usage") or usage

                    served = chunk.get("model") or served
                    if served and served != req.model and not abweichung_gemeldet:
                        abweichung_gemeldet = True
                        yield Status(
                            "generating",
                            note=(
                                f"LM Studio antwortet mit '{served}', angefragt "
                                f"war '{req.model}' - dort ist ein anderes "
                                "Modell geladen"
                            ),
                        )

                    for choice in chunk.get("choices", []):
                        delta = choice.get("delta") or {}

                        # Reasoning-Modelle liefern die Denkschritte je nach
                        # Version unter "reasoning_content" oder "reasoning";
                        # "content" bleibt solange leer.
                        thinking = (
                            delta.get("reasoning_content")
                            or delta.get("reasoning")
                            or ""
                        )
                        if thinking:
                            if first_token_at is None:
                                first_token_at = time.perf_counter()
                            yield Reasoning(thinking)

                        text = delta.get("content") or ""
                        if text:
                            if first_token_at is None:
                                first_token_at = time.perf_counter()
                            yield Delta(text)
                        if choice.get("finish_reason"):
                            finish_reason = choice["finish_reason"]

            yield Done(
                self._metrics(
                    stats, usage, finish_reason, started, first_token_at, served
                )
            )
        except httpx.HTTPError as exc:
            yield Failure(f"Verbindung zu LM Studio abgebrochen: {exc}")

    @staticmethod
    def _message(msg) -> dict[str, Any]:
        if not msg.images:
            return {"role": msg.role, "content": msg.content}
        parts: list[dict[str, Any]] = [{"type": "text", "text": msg.content}]
        for b64 in msg.images:
            parts.append(
                {
                    "type": "image_url",
                    "image_url": {"url": f"data:image/jpeg;base64,{b64}"},
                }
            )
        return {"role": msg.role, "content": parts}

    @staticmethod
    def _metrics(
        stats: dict[str, Any],
        usage: dict[str, Any],
        finish_reason: str | None,
        started: float,
        first_token_at: float | None,
        served: str | None = None,
    ) -> ChatMetrics:
        ttft_s = stats.get("time_to_first_token")
        ttft = (
            round(ttft_s * 1000, 1)
            if isinstance(ttft_s, (int, float))
            else (
                round((first_token_at - started) * 1000, 1)
                if first_token_at is not None
                else None
            )
        )
        total_ms = round((time.perf_counter() - started) * 1000, 1)

        # `stats` kommt bei LM Studio nur im nicht-streamenden Fall. Das
        # Tempo laesst sich aber aus gemessenen Groessen ableiten: erzeugte
        # Tokens geteilt durch die Zeit nach dem ersten Token. Das ist eine
        # eigene Messung, keine Schaetzung - die Herkunft steht in `note`.
        tps = stats.get("tokens_per_second")
        tps_note = "stats fehlen im Abschluss-Chunk"
        if not isinstance(tps, (int, float)):
            erzeugt = usage.get("completion_tokens")
            generierzeit_ms = total_ms - (ttft or 0)
            if isinstance(erzeugt, int) and erzeugt > 1 and generierzeit_ms > 50:
                return ChatMetrics(
                    total_ms=Fact.of(total_ms),
                    load_ms=Fact.unsupported_because(
                        "LM Studio trennt Ladezeit nicht von der Generierung"
                    ),
                    time_to_first_token_ms=Fact.maybe(ttft, "kein Token empfangen"),
                    prompt_tokens=Fact.maybe(
                        usage.get("prompt_tokens"), "usage fehlt im Stream"
                    ),
                    completion_tokens=Fact.of(erzeugt),
                    tokens_per_second=Fact(
                        value=round(erzeugt / (generierzeit_ms / 1000), 2),
                        note="vom Gateway aus Tokenzahl und Dauer berechnet; "
                        "LM Studio liefert im Stream keine eigene Angabe",
                    ),
                    stop_reason=Fact.maybe(finish_reason, "finish_reason fehlt"),
                    served_model=Fact.maybe(served, "Backend nennt kein Modell"),
                )

        return ChatMetrics(
            total_ms=Fact.of(total_ms),
            load_ms=Fact.unsupported_because(
                "LM Studio trennt Ladezeit nicht von der Generierung"
            ),
            time_to_first_token_ms=Fact.maybe(ttft, "kein Token empfangen"),
            prompt_tokens=Fact.maybe(
                usage.get("prompt_tokens"), "usage fehlt im Stream"
            ),
            completion_tokens=Fact.maybe(
                usage.get("completion_tokens"), "usage fehlt im Stream"
            ),
            tokens_per_second=Fact.maybe(tps, tps_note),
            stop_reason=Fact.maybe(finish_reason, "finish_reason fehlt"),
            served_model=Fact.maybe(served, "Backend nennt kein Modell"),
        )

    async def set_keep_alive(self, model: str, *, pin: bool) -> None:
        if pin:
            raise NotSupported(
                "Pinnen geht bei LM Studio nur ueber die TTL-Einstellung in der App"
            )
        # Kein REST-Endpunkt zum Entladen - die CLI kann es, wenn installiert.
        lms = shutil.which("lms")
        if not lms:
            raise NotSupported(
                "Entladen braucht die LM-Studio-CLI ('lms'), die hier nicht gefunden wurde"
            )
        try:
            # In einen Thread ausgelagert: synchron wuerde der Aufruf bis zu
            # 30 s den gesamten Event-Loop blockieren, inklusive laufender
            # Chat-Streams und des Telemetrie-Sockets.
            proc = await asyncio.to_thread(
                subprocess.run,
                [lms, "unload", model],
                capture_output=True,
                text=True,
                timeout=30,
            )
        except subprocess.TimeoutExpired as exc:
            raise BackendError("lms unload hat nicht geantwortet") from exc
        if proc.returncode != 0:
            raise BackendError(
                f"lms unload fehlgeschlagen: {(proc.stderr or proc.stdout)[:200]}"
            )
