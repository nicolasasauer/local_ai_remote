"""Eine vollstaendige Agentenschleife gegen das Gateway.

Frage -> Werkzeugaufruf -> lokale Ausfuehrung -> Ergebnis zurueck -> Antwort.
Genau das, was eine Agenten-CLI tut. Das Werkzeug wird *hier* ausgefuehrt,
nicht im Gateway.
"""

import json
import sys
import time

from openai import OpenAI

BASIS = "http://127.0.0.1:8765/openai/v1"
SCHLUESSEL = "agent-token-nur-fuer-den-test-0123"

WERKZEUGE = [{
    "type": "function",
    "function": {
        "name": "wetter",
        "description": "Liefert das aktuelle Wetter fuer eine Stadt.",
        "parameters": {
            "type": "object",
            "properties": {"stadt": {"type": "string", "description": "Name der Stadt"}},
            "required": ["stadt"],
        },
    },
}]


def wetter(stadt: str) -> str:
    """Das 'Werkzeug'. Laeuft hier, nicht im Gateway."""
    return json.dumps({"stadt": stadt, "temperatur_c": 12, "lage": "bewoelkt"})


def lauf(modell: str, streamend: bool) -> bool:
    c = OpenAI(base_url=BASIS, api_key=SCHLUESSEL, timeout=900.0)
    verlauf = [{"role": "user",
                "content": "Wie ist das Wetter in Berlin? Nutze das Werkzeug."}]
    t0 = time.time()

    def frage(nachrichten):
        if not streamend:
            r = c.chat.completions.create(model=modell, messages=nachrichten,
                                          tools=WERKZEUGE, max_tokens=400)
            return r.choices[0].message, r.choices[0].finish_reason

        stream = c.chat.completions.create(model=modell, messages=nachrichten,
                                           tools=WERKZEUGE, max_tokens=400,
                                           stream=True)
        text, aufrufe, grund = [], {}, None
        for chunk in stream:
            for ch in chunk.choices:
                if ch.delta.content:
                    text.append(ch.delta.content)
                for tc in (ch.delta.tool_calls or []):
                    e = aufrufe.setdefault(tc.index, {"id": "", "name": "", "args": ""})
                    if tc.id:
                        e["id"] = tc.id
                    if tc.function and tc.function.name:
                        e["name"] = tc.function.name
                    if tc.function and tc.function.arguments:
                        e["args"] += tc.function.arguments
                if ch.finish_reason:
                    grund = ch.finish_reason

        class Msg:
            content = "".join(text) or None
            tool_calls = [
                type("TC", (), {
                    "id": e["id"], "type": "function",
                    "function": type("F", (), {"name": e["name"],
                                               "arguments": e["args"]})(),
                })()
                for _, e in sorted(aufrufe.items())
            ] or None

        return Msg(), grund

    nachricht, grund = frage(verlauf)
    print(f"    Zug 1: finish_reason={grund}")

    if grund != "tool_calls" or not nachricht.tool_calls:
        print(f"    KEIN Werkzeugaufruf. content={str(nachricht.content)[:80]!r}")
        return False

    for aufruf in nachricht.tool_calls:
        print(f"    -> {aufruf.function.name}({aufruf.function.arguments})")

    verlauf.append({
        "role": "assistant",
        "content": nachricht.content,
        "tool_calls": [
            {"id": a.id, "type": "function",
             "function": {"name": a.function.name, "arguments": a.function.arguments}}
            for a in nachricht.tool_calls
        ],
    })
    for aufruf in nachricht.tool_calls:
        args = json.loads(aufruf.function.arguments or "{}")
        ergebnis = wetter(args.get("stadt", "?"))
        print(f"    <- {ergebnis}")
        verlauf.append({"role": "tool", "tool_call_id": aufruf.id,
                        "name": aufruf.function.name, "content": ergebnis})

    zweite, grund2 = frage(verlauf)
    print(f"    Zug 2: finish_reason={grund2}")
    print(f"    Antwort: {str(zweite.content)[:160]!r}")
    print(f"    Dauer gesamt: {time.time()-t0:.1f}s")
    return bool(zweite.content)


if __name__ == "__main__":
    modell = sys.argv[1]
    streamend = "--stream" in sys.argv
    art = "streamend" if streamend else "nicht-streamend"
    print(f"=== {modell} ({art}) ===")
    try:
        ok = lauf(modell, streamend)
        print("    ERGEBNIS:", "vollstaendige Schleife" if ok else "unvollstaendig")
    except Exception as e:
        print(f"    FEHLER {type(e).__name__}: {str(e)[:300]}")
