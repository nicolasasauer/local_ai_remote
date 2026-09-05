"""Ollama-Adapter.

Der Ladezustand entsteht aus der Differenz zweier Routen:
``/api/tags`` kennt alle installierten Modelle, ``/api/ps`` nur die aktuell im
Speicher liegenden - inklusive ``size_vram`` und ``expires_at``.
"""

from __future__ import annotations

import asyncio
import json
import time
from datetime import datetime
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
    ToolCall,
)
from .base import (
    Backend,
    BackendError,
    ChatEvent,
    Delta,
    Done,
    Failure,
    Reasoning,
    Status,
    ToolCalls,
)

_NO_CAPS_NOTE = (
    "Diese Ollama-Version liefert kein capabilities-Feld in /api/show; "
    "Vision-Faehigkeit nicht sicher bestimmbar"
)


def _parse_expiry(raw: str | None) -> datetime | None:
    if not raw:
        return None
    try:
        cleaned = raw.replace("Z", "+00:00")
        parsed = datetime.fromisoformat(cleaned)
    except ValueError:
        return None
    # Ollama benutzt ein Jahr weit in der Zukunft fuer keep_alive=-1.
    if parsed.year > datetime.now().year + 5:
        return None
    return parsed


def _als_objekt(arguments: str) -> Any:
    """Argumente zurueck in ein Objekt, wie Ollama sie erwartet.

    Laesst sich der String nicht lesen, geht er unveraendert weiter: eine
    Reparatur waere geraten, und das Modell hat ihn so erzeugt.
    """
    try:
        return json.loads(arguments)
    except (json.JSONDecodeError, TypeError):
        return arguments


def _tool_calls(message: dict[str, Any]) -> list[ToolCall]:
    """Werkzeugaufrufe aus einem Ollama-Chunk.

    Ollama liefert sie vollstaendig und mit eigener Id; die Argumente kommen
    als Objekt und werden fuer die einheitliche Form serialisiert.
    """
    roh = message.get("tool_calls")
    if not isinstance(roh, list):
        return []

    out: list[ToolCall] = []
    for i, eintrag in enumerate(roh):
        funktion = eintrag.get("function") or {}
        name = funktion.get("name")
        if not name:
            continue
        argumente = funktion.get("arguments")
        if not isinstance(argumente, str):
            argumente = json.dumps(argumente or {}, ensure_ascii=False)
        out.append(
            ToolCall(
                id=str(eintrag.get("id") or f"call_{i}"),
                name=str(name),
                arguments=argumente,
            )
        )
    return out


class OllamaBackend(Backend):
    id = BackendId.ollama

    def __init__(self, base_url: str, client: httpx.AsyncClient) -> None:
        super().__init__(base_url, client)
        # /api/show kostet einen Request pro Modell, deshalb Cache nach Digest.
        self._detail_cache: dict[str, dict[str, Any]] = {}

    async def health(self) -> BackendHealth:
        try:
            res = await self.http.get(self._url("/api/version"), timeout=5)
            res.raise_for_status()
            version = res.json().get("version")
            return BackendHealth(
                backend=self.id,
                reachable=True,
                version=Fact.maybe(version, "Version nicht im Response enthalten"),
            )
        except Exception as exc:  # noqa: BLE001 - Grund geht an den Client
            return BackendHealth(
                backend=self.id,
                reachable=False,
                version=Fact.unknown_because("Backend nicht erreichbar"),
                message=str(exc),
            )

    async def list_models(self) -> list[ModelEntry]:
        tags, running = await asyncio.gather(
            self._get_json("/api/tags"),
            self._get_json("/api/ps"),
            return_exceptions=True,
        )
        if isinstance(tags, Exception):
            raise BackendError(f"/api/tags fehlgeschlagen: {tags}")

        loaded: dict[str, dict[str, Any]] = {}
        ps_failed: str | None = None
        if isinstance(running, Exception):
            ps_failed = str(running)
        else:
            loaded = {m["name"]: m for m in running.get("models", [])}

        installed = tags.get("models", [])
        details = await self._fetch_details([m["name"] for m in installed])

        entries: list[ModelEntry] = []
        for raw in installed:
            name = raw["name"]
            live = loaded.get(name)
            entries.append(self._to_entry(raw, live, details.get(name), ps_failed))
        return entries

    def _to_entry(
        self,
        raw: dict[str, Any],
        live: dict[str, Any] | None,
        detail: dict[str, Any] | None,
        ps_failed: str | None,
    ) -> ModelEntry:
        name = raw["name"]
        meta = raw.get("details") or {}

        if ps_failed:
            state = ModelState.error
        elif live:
            state = ModelState.loaded
        else:
            state = ModelState.not_loaded

        # VRAM-Anteil: size ist die Gesamtgroesse im Speicher, size_vram der
        # Teil auf der GPU. Ein Verhaeltnis < 1 heisst Auslagerung in den RAM
        # und erklaert unerwartet langsame Antworten.
        vram = Fact[int].unsupported_because("nur fuer geladene Modelle verfuegbar")
        fraction = Fact[float].unsupported_because("nur fuer geladene Modelle verfuegbar")
        expires = Fact[datetime].unsupported_because("nur fuer geladene Modelle verfuegbar")
        loaded_ctx = Fact[int].unsupported_because("nur fuer geladene Modelle verfuegbar")

        if live:
            total = live.get("size")
            in_vram = live.get("size_vram")
            vram = Fact.maybe(in_vram, "size_vram fehlt in /api/ps")
            if total and in_vram is not None and total > 0:
                fraction = Fact.of(round(in_vram / total, 4))
            else:
                fraction = Fact.unknown_because("size oder size_vram fehlt in /api/ps")
            expiry = _parse_expiry(live.get("expires_at"))
            expires = (
                Fact.of(expiry)
                if expiry
                else Fact.unknown_because("kein Ablauf gesetzt (gepinnt) oder Feld fehlt")
            )
            ctx = (live.get("context_length") or 0) or None
            loaded_ctx = Fact.maybe(ctx, "context_length fehlt in /api/ps")

        vision = Fact[bool].unknown_because(_NO_CAPS_NOTE)
        tools = Fact[bool].unknown_because(_NO_CAPS_NOTE)
        thinking = Fact[bool].unknown_because(_NO_CAPS_NOTE)
        ctx_len = Fact[int].unknown_because("/api/show nicht abrufbar")

        if detail is not None:
            caps = detail.get("capabilities")
            if isinstance(caps, list):
                vision = Fact.of("vision" in caps)
                tools = Fact.of("tools" in caps)
                thinking = Fact.of("thinking" in caps)
            info = detail.get("model_info") or {}
            arch = info.get("general.architecture")
            ctx_value = info.get(f"{arch}.context_length") if arch else None
            ctx_len = Fact.maybe(
                ctx_value, "context_length nicht in model_info enthalten"
            )

        kind = ModelKind.unknown
        if vision.value is True:
            kind = ModelKind.vision
        elif vision.value is False:
            kind = ModelKind.llm

        return ModelEntry(
            id=name,
            label=name,
            backend=self.id,
            state=state,
            kind=kind,
            family=Fact.maybe(meta.get("family"), "details.family fehlt"),
            parameter_size=Fact.maybe(
                meta.get("parameter_size"), "details.parameter_size fehlt"
            ),
            quantization=Fact.maybe(
                meta.get("quantization_level"), "details.quantization_level fehlt"
            ),
            disk_bytes=Fact.maybe(raw.get("size"), "size fehlt in /api/tags"),
            vram_bytes=vram,
            vram_fraction=fraction,
            context_length=ctx_len,
            loaded_context_length=loaded_ctx,
            unloads_at=expires,
            vision=vision,
            tools=tools,
            thinking=thinking,
            error=ps_failed,
        )

    async def _fetch_details(self, names: list[str]) -> dict[str, dict[str, Any]]:
        """``/api/show`` fuer alle Modelle, parallel und gecacht."""
        out: dict[str, dict[str, Any]] = {}
        missing = []
        for name in names:
            if name in self._detail_cache:
                out[name] = self._detail_cache[name]
            else:
                missing.append(name)

        if not missing:
            return out

        limit = asyncio.Semaphore(6)

        async def one(name: str) -> None:
            async with limit:
                try:
                    res = await self.http.post(
                        self._url("/api/show"), json={"model": name}, timeout=20
                    )
                    res.raise_for_status()
                    data = res.json()
                except Exception:  # noqa: BLE001 - bleibt schlicht unbekannt
                    return
                self._detail_cache[name] = data
                out[name] = data

        await asyncio.gather(*(one(n) for n in missing))
        return out

    async def _supports_thinking(self, model: str) -> bool:
        """Aus dem /api/show-Cache; bei Unbekanntem lieber False als ein
        Request, den das Modell mit einem Fehler quittiert."""
        detail = self._detail_cache.get(model)
        if detail is None:
            detail = (await self._fetch_details([model])).get(model)
        caps = (detail or {}).get("capabilities")
        return isinstance(caps, list) and "thinking" in caps

    async def stream_chat(self, req: ChatRequest) -> AsyncIterator[ChatEvent]:
        payload: dict[str, Any] = {
            "model": req.model,
            "messages": [self._message(m) for m in req.messages],
            "stream": True,
        }
        if req.tools:
            payload["tools"] = req.tools
        if req.tool_choice is not None:
            payload["tool_choice"] = req.tool_choice

        # Ohne "think" liefert Ollama bei Reasoning-Modellen weder thinking
        # noch content - die Antwort bliebe leer. None heisst: anhand der
        # Faehigkeiten des Modells entscheiden.
        think = req.think
        if think is None:
            think = await self._supports_thinking(req.model)
        if think:
            payload["think"] = True

        # Was der Aufrufer setzt, wird gesetzt. Ein still verworfener
        # Parameter erzeugt eine Antwort, die anders zustande kam als
        # angefordert - und niemand sieht warum.
        options: dict[str, Any] = {}
        if req.temperature is not None:
            options["temperature"] = req.temperature
        if req.top_p is not None:
            options["top_p"] = req.top_p
        if req.max_tokens is not None:
            options["num_predict"] = req.max_tokens
        if req.stop:
            options["stop"] = req.stop
        if req.seed is not None:
            options["seed"] = req.seed
        if req.presence_penalty is not None:
            options["presence_penalty"] = req.presence_penalty
        if req.frequency_penalty is not None:
            options["frequency_penalty"] = req.frequency_penalty
        if options:
            payload["options"] = options
        if req.json_mode:
            payload["format"] = "json"

        started = time.perf_counter()
        first_token_at: float | None = None
        hatte_aufrufe = False

        try:
            async with self.http.stream(
                "POST", self._url("/api/chat"), json=payload
            ) as res:
                if res.status_code != 200:
                    body = (await res.aread()).decode(errors="replace")
                    yield Failure(f"Ollama antwortete {res.status_code}: {body[:400]}")
                    return

                async for line in res.aiter_lines():
                    if not line.strip():
                        continue
                    try:
                        chunk = json.loads(line)
                    except json.JSONDecodeError:
                        continue

                    if chunk.get("error"):
                        yield Failure(str(chunk["error"]))
                        return

                    message = chunk.get("message") or {}

                    # Reasoning-Modelle (Qwen3, gemma-4, deepseek-r1 ...)
                    # schreiben ihre Denkschritte nach "thinking" und lassen
                    # "content" so lange leer. Wer nur content liest, sieht bei
                    # diesen Modellen gar nichts.
                    thinking = message.get("thinking") or ""
                    if thinking:
                        if first_token_at is None:
                            first_token_at = time.perf_counter()
                        yield Reasoning(thinking)

                    text = message.get("content") or ""
                    if text:
                        if first_token_at is None:
                            first_token_at = time.perf_counter()
                        yield Delta(text)

                    aufrufe = _tool_calls(message)
                    if aufrufe:
                        if first_token_at is None:
                            first_token_at = time.perf_counter()
                        hatte_aufrufe = True
                        yield ToolCalls(aufrufe)

                    if chunk.get("done"):
                        yield Done(
                            self._metrics(
                                chunk, started, first_token_at, hatte_aufrufe
                            )
                        )
                        return
        except httpx.HTTPError as exc:
            yield Failure(f"Verbindung zu Ollama abgebrochen: {exc}")

    @staticmethod
    def _message(msg) -> dict[str, Any]:
        out: dict[str, Any] = {"role": msg.role, "content": msg.content}
        if msg.images:
            out["images"] = msg.images
        if msg.tool_calls:
            # Ollama erwartet die Argumente als Objekt, nicht als String.
            out["tool_calls"] = [
                {
                    "id": call.id,
                    "function": {
                        "name": call.name,
                        "arguments": _als_objekt(call.arguments),
                    },
                }
                for call in msg.tool_calls
            ]
        if msg.role == "tool":
            # Ollama ordnet Ergebnisse ueber den Namen zu, nicht ueber die Id.
            if msg.tool_name:
                out["tool_name"] = msg.tool_name
            if msg.tool_call_id:
                out["tool_call_id"] = msg.tool_call_id
        return out

    @staticmethod
    def _metrics(
        chunk: dict[str, Any],
        started: float,
        first_token_at: float | None,
        hatte_aufrufe: bool = False,
    ) -> ChatMetrics:
        eval_count = chunk.get("eval_count")
        eval_ns = chunk.get("eval_duration")
        tps = None
        if eval_count and eval_ns:
            tps = round(eval_count / (eval_ns / 1e9), 2)

        load_ns = chunk.get("load_duration")
        ttft = (
            round((first_token_at - started) * 1000, 1)
            if first_token_at is not None
            else None
        )

        return ChatMetrics(
            total_ms=Fact.of(round((time.perf_counter() - started) * 1000, 1)),
            load_ms=Fact.maybe(
                round(load_ns / 1e6, 1) if load_ns else None,
                "load_duration fehlt im Abschluss-Chunk",
            ),
            time_to_first_token_ms=Fact.maybe(ttft, "kein Token empfangen"),
            prompt_tokens=Fact.maybe(
                chunk.get("prompt_eval_count"), "prompt_eval_count fehlt"
            ),
            completion_tokens=Fact.maybe(eval_count, "eval_count fehlt"),
            tokens_per_second=Fact.maybe(
                tps, "eval_count oder eval_duration fehlt"
            ),
            # Ollama meldet auch bei Werkzeugaufrufen "stop". OpenAI-Clients
            # unterscheiden aber danach, ob sie Werkzeuge ausfuehren muessen -
            # also wird der Grund hier auf das gehoben, was tatsaechlich
            # passiert ist.
            stop_reason=(
                Fact.of("tool_calls")
                if hatte_aufrufe
                else Fact.maybe(
                    chunk.get("done_reason"),
                    "done_reason fehlt (aeltere Ollama-Version)",
                )
            ),
            served_model=Fact.maybe(chunk.get("model"), "Backend nennt kein Modell"),
        )

    async def set_keep_alive(self, model: str, *, pin: bool) -> None:
        # Ein leerer generate-Request mit keep_alive steuert nur den Speicher:
        # -1 pinnt das Modell, 0 entlaedt es sofort.
        res = await self.http.post(
            self._url("/api/generate"),
            json={"model": model, "keep_alive": -1 if pin else 0},
            timeout=30,
        )
        if res.status_code != 200:
            raise BackendError(
                f"keep_alive fehlgeschlagen ({res.status_code}): {res.text[:200]}"
            )

    async def _get_json(self, path: str) -> dict[str, Any]:
        res = await self.http.get(self._url(path), timeout=15)
        res.raise_for_status()
        return res.json()
