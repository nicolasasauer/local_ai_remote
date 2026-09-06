"""Gateway zwischen der Flutter-App und den lokalen Inferenz-Servern."""

from __future__ import annotations

import asyncio
import json
import platform
import secrets
from contextlib import asynccontextmanager
from typing import AsyncIterator

import httpx
import uvicorn
from fastapi import Depends, FastAPI, Header, HTTPException, Query, Request, WebSocket
from fastapi.responses import JSONResponse, StreamingResponse
from pydantic import BaseModel
from starlette.websockets import WebSocketDisconnect

from .backends.base import (
    Backend,
    BackendError,
    Delta,
    Done,
    Failure,
    Reasoning,
    Status,
    ToolCalls,
)
from .backends.lmstudio import LmStudioBackend
from .backends.ollama import OllamaBackend
from .config import CONFIG, ConfigError
from .openai_api import router as openai_router
from .responses_api import router as responses_router
from . import research
from .schema import (
    BackendId,
    ChatRequest,
    GatewayHealth,
    ModelEntry,
    ModelRef,
    ModelState,
)
from .telemetry import TelemetryReader

VERSION = "0.1.0"

_http: httpx.AsyncClient | None = None
_backends: dict[BackendId, Backend] = {}
_reader = TelemetryReader()


@asynccontextmanager
async def lifespan(_: FastAPI) -> AsyncIterator[None]:
    """Ein HTTP-Client fuer den gesamten Prozess: Verbindungen zu den Backends
    bleiben offen, statt pro Anfrage neu aufgebaut zu werden."""
    global _http
    _http = httpx.AsyncClient(timeout=CONFIG.request_timeout)
    _backends[BackendId.ollama] = OllamaBackend(CONFIG.ollama_url, _http)
    _backends[BackendId.lmstudio] = LmStudioBackend(CONFIG.lmstudio_url, _http)
    # Der OpenAI-Router greift ueber den App-Zustand darauf zu, statt das
    # Modul-Global zu importieren - so laesst er sich im Test austauschen.
    app.state.backends = _backends
    try:
        yield
    finally:
        await _http.aclose()


app = FastAPI(title="Local AI Gateway", version=VERSION, lifespan=lifespan)
app.include_router(openai_router)
app.include_router(responses_router)


@app.exception_handler(HTTPException)
async def _fehlerhuelle(request: Request, exc: HTTPException) -> JSONResponse:
    """OpenAI-Clients lesen `error.message` auf oberster Ebene.

    FastAPI verpackt jedes `detail` zusaetzlich in ein `detail`-Objekt. Fuer
    die App-API ist das egal, fuer Werkzeuge nicht: sie finden die Meldung
    dann nicht und zeigen "unknown error".
    """
    if isinstance(exc.detail, dict) and "error" in exc.detail:
        return JSONResponse(status_code=exc.status_code, content=exc.detail)
    return JSONResponse(
        status_code=exc.status_code,
        content={"detail": exc.detail},
        headers=getattr(exc, "headers", None),
    )


@app.middleware("http")
async def _limit_body(request: Request, call_next):
    """Obergrenze fuer den Anfragekoerper.

    Agenten-Werkzeuge schicken ganze Projektdateien mit. Ohne Grenze zieht
    eine einzige verirrte Anfrage den Speicher des Desktops leer - und der
    Desktop ist hier auch der Rechner, auf dem das Modell laeuft.
    """
    raw = request.headers.get("content-length")
    if raw and raw.isdigit() and int(raw) > CONFIG.max_request_bytes:
        return JSONResponse(
            status_code=413,
            content={
                "error": {
                    "message": (
                        f"Anfrage ist groesser als das Limit von "
                        f"{CONFIG.max_request_bytes} Bytes "
                        "(GATEWAY_MAX_REQUEST_BYTES)."
                    ),
                    "type": "invalid_request_error",
                }
            },
        )
    return await call_next(request)


def require_token(authorization: str | None = Header(default=None)) -> None:
    """Zweite Schicht hinter den Tailnet-ACLs."""
    if not CONFIG.token:
        return
    expected = f"Bearer {CONFIG.token}"
    if not secrets.compare_digest(authorization or "", expected):
        raise HTTPException(status_code=401, detail="Ungueltiger Token")


def _backend(backend_id: BackendId) -> Backend:
    try:
        return _backends[backend_id]
    except KeyError:
        raise HTTPException(status_code=404, detail=f"Backend {backend_id} unbekannt")


@app.get("/v1/health", response_model=GatewayHealth)
async def health(_: None = Depends(require_token)) -> GatewayHealth:
    results = await asyncio.gather(*(b.health() for b in _backends.values()))
    return GatewayHealth(
        ok=True,
        hostname=platform.node(),
        gateway_version=VERSION,
        backends=list(results),
    )


@app.get("/v1/models")
async def list_models(_: None = Depends(require_token)) -> dict:
    """Modelle beider Backends. Ein ausgefallenes Backend blockiert die
    Antwort nicht, sondern erscheint als Eintrag in ``errors``."""
    ids = list(_backends.keys())
    results = await asyncio.gather(
        *(_backends[i].list_models() for i in ids), return_exceptions=True
    )

    models: list[ModelEntry] = []
    errors: list[dict[str, str]] = []
    for backend_id, result in zip(ids, results):
        if isinstance(result, Exception):
            errors.append({"backend": backend_id.value, "message": str(result)})
        else:
            models.extend(result)

    return {
        "models": [m.model_dump(mode="json") for m in models],
        "errors": errors,
    }


@app.post("/v1/models/pin")
async def pin_model(ref: ModelRef, _: None = Depends(require_token)) -> dict:
    try:
        await _backend(ref.backend).set_keep_alive(ref.model, pin=True)
    except BackendError as exc:
        raise HTTPException(status_code=exc.status_code, detail=exc.message)
    return {"state": ModelState.loaded.value, "unloads_at": None}


@app.post("/v1/models/unload")
async def unload_model(ref: ModelRef, _: None = Depends(require_token)) -> dict:
    try:
        await _backend(ref.backend).set_keep_alive(ref.model, pin=False)
    except BackendError as exc:
        raise HTTPException(status_code=exc.status_code, detail=exc.message)
    return {"state": ModelState.unloading.value}


def _sse(payload: dict) -> str:
    return f"data: {json.dumps(payload, ensure_ascii=False)}\n\n"


HEARTBEAT_INTERVAL = 10.0


@app.post("/v1/chat")
async def chat(req: ChatRequest, _: None = Depends(require_token)) -> StreamingResponse:
    backend = _backend(req.backend)

    if req.research:
        if not CONFIG.research_enabled:
            raise HTTPException(
                status_code=409,
                detail="Recherche ist auf diesem Gateway nicht eingeschaltet "
                "(GATEWAY_RESEARCH=1).",
            )
        # Der Katalog gehoert dem Gateway, nicht dem Aufrufer. Die App
        # schaltet Recherche ein oder aus; sie kann keine eigenen Werkzeuge
        # definieren, die das Gateway dann ausfuehren wuerde.
        req = req.model_copy(update={"tools": research.katalog()})

    async def produce(queue: "asyncio.Queue[str | None]") -> None:
        try:
            # Wenn das Modell kalt ist, dauert der erste Token oft Minuten.
            # Ohne dieses Event sieht die App nur eine haengende Verbindung.
            try:
                entries = await backend.list_models()
                match = next((m for m in entries if m.id == req.model), None)
                if match is not None and match.state is not ModelState.loaded:
                    await queue.put(
                        _sse(
                            {
                                "type": "status",
                                "state": "loading_model",
                                "note": "Modell ist nicht im Speicher und wird geladen",
                            }
                        )
                    )
            except Exception:  # noqa: BLE001 - reine Zusatzinfo
                pass

            await queue.put(
                _sse({"type": "status", "state": "processing_prompt", "note": None})
            )

            async for event in backend.stream_chat(req):
                if isinstance(event, Delta):
                    await queue.put(_sse({"type": "delta", "text": event.text}))
                elif isinstance(event, Reasoning):
                    await queue.put(_sse({"type": "reasoning", "text": event.text}))
                elif isinstance(event, ToolCalls):
                    await queue.put(
                        _sse(
                            {
                                "type": "tool_calls",
                                "calls": [c.model_dump() for c in event.calls],
                            }
                        )
                    )
                elif isinstance(event, Status):
                    await queue.put(
                        _sse(
                            {"type": "status", "state": event.state, "note": event.note}
                        )
                    )
                elif isinstance(event, Done):
                    await queue.put(
                        _sse(
                            {
                                "type": "done",
                                "metrics": event.metrics.model_dump(mode="json"),
                            }
                        )
                    )
                elif isinstance(event, Failure):
                    await queue.put(_sse({"type": "error", "message": event.message}))
        except Exception as exc:  # noqa: BLE001
            await queue.put(_sse({"type": "error", "message": f"Gateway-Fehler: {exc}"}))
        finally:
            await queue.put(None)

    async def stream() -> AsyncIterator[str]:
        queue: asyncio.Queue[str | None] = asyncio.Queue()
        task = asyncio.create_task(produce(queue))
        # Sofort quittieren: ab hier weiss die App, dass der Prompt angekommen
        # ist - noch bevor das Backend ueberhaupt geantwortet hat.
        yield _sse({"type": "status", "state": "accepted", "note": None})
        try:
            while True:
                try:
                    item = await asyncio.wait_for(
                        queue.get(), timeout=HEARTBEAT_INTERVAL
                    )
                except asyncio.TimeoutError:
                    # Lebenszeichen: unterscheidet "rechnet noch" von
                    # "Verbindung tot". Ohne das bleibt nur ein Timeout,
                    # der beides gleich aussehen laesst.
                    yield _sse({"type": "heartbeat"})
                    continue
                if item is None:
                    return
                yield item
        finally:
            task.cancel()

    return StreamingResponse(
        stream(),
        media_type="text/event-stream",
        headers={"Cache-Control": "no-cache", "X-Accel-Buffering": "no"},
    )


class ResearchRequest(BaseModel):
    """Ein Werkzeugaufruf, den der Nutzer in der App freigegeben hat."""

    name: str
    arguments: str = "{}"


@app.post("/v1/research")
async def research_ausfuehren(
    req: ResearchRequest, _: None = Depends(require_token)
) -> dict:
    """Fuehrt genau einen freigegebenen Recherche-Aufruf aus.

    Bewusst ein eigener Endpunkt statt eines Schritts im Chat-Stream: so
    laeuft nichts, ohne dass die App es einzeln angefordert hat. Zwischen
    Vorschlag des Modells und Ausfuehrung liegt eine Nutzerentscheidung.
    """
    if not CONFIG.research_enabled:
        raise HTTPException(
            status_code=409,
            detail="Recherche ist auf diesem Gateway nicht eingeschaltet "
            "(GATEWAY_RESEARCH=1).",
        )
    if not research.ist_recherchewerkzeug(req.name):
        raise HTTPException(
            status_code=400,
            detail=f"'{req.name}' ist kein Recherche-Werkzeug dieses Gateways.",
        )
    if _http is None:
        raise HTTPException(status_code=503, detail="Gateway startet noch")

    try:
        ergebnis = await research.ausfuehren(_http, req.name, req.arguments)
    except research.RechercheFehler as exc:
        # Der Grund geht an die App und von dort ins Gespraech: ein
        # gescheiterter Abruf ist eine Information, kein stiller Ausfall.
        raise HTTPException(status_code=422, detail=str(exc))
    except httpx.HTTPError as exc:
        raise HTTPException(status_code=502, detail=f"Abruf fehlgeschlagen: {exc}")
    return ergebnis.model_dump(mode="json")


@app.websocket("/v1/telemetry")
async def telemetry(ws: WebSocket, token: str = Query(default="")) -> None:
    if CONFIG.token and not secrets.compare_digest(token, CONFIG.token):
        await ws.close(code=4401)
        return

    await ws.accept()
    try:
        while True:
            sample = await asyncio.to_thread(_reader.sample)
            await ws.send_text(json.dumps(sample.model_dump(mode="json")))
            await asyncio.sleep(CONFIG.telemetry_interval)
    except (WebSocketDisconnect, RuntimeError):
        return


def run() -> None:
    # Fail-fast statt still ungeschuetzt zu starten: ein leerer Token wuerde
    # require_token wirkungslos machen, und hinter `tailscale serve` haengt das
    # Gateway dann offen im Tailnet.
    try:
        CONFIG.check()
    except ConfigError as exc:
        raise SystemExit(f"Start abgebrochen: {exc}")
    if CONFIG.agents_enabled:
        print(
            "OpenAI-kompatible Oberflaeche aktiv unter "
            f"http://{CONFIG.bind_host}:{CONFIG.bind_port}/openai/v1"
        )
    else:
        print(
            "OpenAI-kompatible Oberflaeche aus "
            "(GATEWAY_AGENT_TOKEN setzen, um sie einzuschalten)"
        )
    uvicorn.run(app, host=CONFIG.bind_host, port=CONFIG.bind_port, log_level="info")


if __name__ == "__main__":
    run()
