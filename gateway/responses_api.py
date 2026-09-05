"""Responses-API fuer Agenten-CLIs, die kein Chat-Completions mehr sprechen.

Die Codex CLI hat ``wire_api = "chat"`` fallengelassen und verlangt die
Responses-API. Anders als bei ``/openai/v1/chat/completions`` uebersetzt das
Gateway hier **nicht**, sondern leitet weiter: beide Backends implementieren
die Route bereits nativ und in derselben Form.

Was das Gateway beitraegt, ist trotzdem genau das, wofuer es da ist:

* Auth und Erreichbarkeit ueber das Tailnet
* Aufloesung des Modellnamens auf das richtige Backend
* Normalisierung der Werkzeugliste - ohne die scheitert die Codex CLI an
  Ollama mit HTTP 500

Der Preis der Weiterleitung: Antwortfelder gehen unveraendert durch, also auch
die des Backends. Wer beide Backends vergleichen will, sieht hier ihre
Unterschiede statt einer gemeinsamen Form. Fuer eine Agenten-CLI ist das
richtig - sie erwartet die Form ihres Anbieters, nicht unsere.
"""

from __future__ import annotations

import json
import logging
from typing import Any, AsyncIterator

import httpx
from fastapi import APIRouter, Depends, Request
from fastapi.responses import JSONResponse, StreamingResponse

from .backends.base import Backend
from .openai_api import _error, require_agent_token, resolve, split_qualified
from .schema import BackendId

log = logging.getLogger("gateway.responses")

router = APIRouter(prefix="/openai/v1", tags=["openai"])

#: Die Responses-API kennt neben Funktionen eingebaute Werkzeugtypen
#: (``web_search``, ``image_generation``, ``computer_use`` ...). Kein lokales
#: Backend kann sie, und Ollama beendet die Anfrage mit HTTP 500, statt sie zu
#: uebergehen - eine einzige Zeile in der Werkzeugliste macht die ganze
#: Sitzung unbrauchbar.
_UNTERSTUETZT = {"function"}


def normalisiere_werkzeuge(tools: Any) -> tuple[list[dict[str, Any]], list[str]]:
    """Behaelt Funktionen, verwirft alles andere und nennt das Verworfene.

    Stillschweigend etwas anderes zu tun als angefordert ist sonst nicht die
    Art dieses Gateways. Hier ist die Alternative aber, dass gar nichts geht:
    Codex bietet seine eingebauten Werkzeuge immer mit an, und Ollama lehnt
    die gesamte Anfrage deswegen ab. Verworfenes wird deshalb protokolliert.
    """
    if not isinstance(tools, list):
        return [], []

    behalten: list[dict[str, Any]] = []
    verworfen: list[str] = []
    for werkzeug in tools:
        if not isinstance(werkzeug, dict):
            continue
        art = werkzeug.get("type")
        if art in _UNTERSTUETZT:
            behalten.append(werkzeug)
        else:
            verworfen.append(str(art))
    return behalten, verworfen


def _text_von(eintrag: dict[str, Any]) -> str:
    """Text eines Eingabe-Elements, egal ob String oder Teile-Liste."""
    inhalt = eintrag.get("content")
    if isinstance(inhalt, str):
        return inhalt
    if isinstance(inhalt, list):
        return "\n".join(
            str(teil.get("text", ""))
            for teil in inhalt
            if isinstance(teil, dict) and teil.get("text")
        )
    return ""


def falte_systemnachrichten(payload: dict[str, Any]) -> bool:
    """Fuehrt ``instructions`` und ``developer``-Eintraege zu *einer* Anweisung
    am Anfang zusammen. Gibt zurueck, ob etwas zusammengefasst wurde.

    Die Codex CLI schickt beides gleichzeitig: eine lange ``instructions`` und
    zusaetzlich einen Eintrag mit der Rolle ``developer``. Ollama macht daraus
    zwei Systemnachrichten - und strenge Chat-Vorlagen (Qwen3.6 etwa) brechen
    dann mit "System message must be at the beginning" ab, HTTP 500, die
    ganze Sitzung unbrauchbar.

    Zusammengefasst wird unter Erhalt von Inhalt und Reihenfolge:
    ``instructions`` zuerst, dann die Entwickler-Anweisungen. Es geht nichts
    verloren, es steht nur alles an einer Stelle.
    """
    eingabe = payload.get("input")
    if not isinstance(eingabe, list):
        return False

    vorangestellt: list[str] = []
    rest: list[Any] = []
    for eintrag in eingabe:
        if isinstance(eintrag, dict) and eintrag.get("role") in ("developer", "system"):
            text = _text_von(eintrag)
            if text:
                vorangestellt.append(text)
        else:
            rest.append(eintrag)

    if not vorangestellt:
        return False

    teile = [str(payload["instructions"])] if payload.get("instructions") else []
    teile.extend(vorangestellt)
    payload["instructions"] = "\n\n".join(teile)
    payload["input"] = rest
    return True


def _ziel(adapter: Backend) -> str:
    return f"{adapter.base_url}/v1/responses"


@router.post("/responses")
async def responses(request: Request, _: None = Depends(require_agent_token)):
    try:
        body = await request.json()
    except Exception:  # noqa: BLE001
        raise _error(400, "Anfragekoerper ist kein gueltiges JSON")

    if not isinstance(body, dict) or not body.get("model"):
        raise _error(400, "Feld 'model' fehlt")

    backends: dict[BackendId, Backend] = request.app.state.backends
    backend_id, modell = await resolve(str(body["model"]), backends)
    adapter = backends[backend_id]

    weiterleitung = dict(body)
    weiterleitung["model"] = modell

    if "tools" in weiterleitung:
        behalten, verworfen = normalisiere_werkzeuge(weiterleitung["tools"])
        weiterleitung["tools"] = behalten
        if verworfen:
            log.warning(
                "Werkzeugtypen verworfen, die kein lokales Backend kann: %s",
                ", ".join(sorted(set(verworfen))),
            )

    if falte_systemnachrichten(weiterleitung):
        log.info(
            "developer-Anweisungen in 'instructions' gefaltet - strenge "
            "Chat-Vorlagen lassen nur eine Systemnachricht am Anfang zu"
        )

    if weiterleitung.get("stream"):
        return StreamingResponse(
            _weiterleiten_streamend(adapter, weiterleitung),
            media_type="text/event-stream",
            headers={"Cache-Control": "no-cache", "X-Accel-Buffering": "no"},
        )
    return await _weiterleiten(adapter, weiterleitung, body["model"])


async def _weiterleiten(
    adapter: Backend, payload: dict[str, Any], label: str
) -> JSONResponse:
    try:
        res = await adapter.http.post(_ziel(adapter), json=payload)
    except httpx.HTTPError as exc:
        raise _error(502, f"Backend nicht erreichbar: {exc}", "upstream_error")

    try:
        inhalt = res.json()
    except ValueError:
        raise _error(
            502,
            f"Backend antwortete {res.status_code} ohne verwertbaren Inhalt",
            "upstream_error",
        )

    if res.status_code >= 400:
        # Die Meldung des Backends durchreichen: sie nennt den Grund genauer,
        # als das Gateway ihn raten koennte.
        return JSONResponse(status_code=res.status_code, content=inhalt)

    _praefix_setzen(inhalt, label)
    return JSONResponse(content=inhalt)


async def _weiterleiten_streamend(
    adapter: Backend, payload: dict[str, Any]
) -> AsyncIterator[bytes]:
    try:
        async with adapter.http.stream(
            "POST", _ziel(adapter), json=payload
        ) as res:
            if res.status_code >= 400:
                roh = (await res.aread()).decode(errors="replace")
                yield (
                    b"data: "
                    + json.dumps(
                        {
                            "error": {
                                "message": f"Backend antwortete {res.status_code}: "
                                f"{roh[:400]}",
                                "type": "upstream_error",
                            }
                        }
                    ).encode()
                    + b"\n\n"
                )
                return
            async for stueck in res.aiter_raw():
                yield stueck
    except httpx.HTTPError as exc:
        yield (
            b"data: "
            + json.dumps(
                {
                    "error": {
                        "message": f"Verbindung zum Backend abgebrochen: {exc}",
                        "type": "upstream_error",
                    }
                }
            ).encode()
            + b"\n\n"
        )


def _praefix_setzen(inhalt: Any, label: str) -> None:
    """Modellnamen wieder mit Backend-Praefix melden.

    Der Client hat ``ollama/x`` angefragt; bekaeme er ``x`` zurueck, koennte er
    den Namen nicht wiederverwenden. Bleibt das Backend bei einem anderen
    Modell, steht auch das hier - so wie im Chat-Completions-Teil.
    """
    if not isinstance(inhalt, dict) or not inhalt.get("model"):
        return
    backend, _ = split_qualified(label)
    if backend is not None:
        inhalt["model"] = f"{backend.value}/{inhalt['model']}"
