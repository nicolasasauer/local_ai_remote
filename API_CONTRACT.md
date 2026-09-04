# Gateway-API v1

Die Flutter-App spricht **nie** direkt mit Ollama oder LM Studio, sondern immer mit dem
Gateway auf dem Desktop. Das Gateway normalisiert beide Backends auf dieses Schema.

Transport: HTTPS über `tailscale serve`, Auth per `Authorization: Bearer <token>`.
Beim WebSocket wird der Token als Query-Parameter `?token=` übergeben (Header sind bei
WebSockets nicht überall zuverlässig).

Backend-Kennungen: `ollama` | `lmstudio`

Daneben gibt es unter `/openai/v1` eine zweite, davon unabhaengige Oberflaeche
im Chat-Completions-Format fuer Agenten-Werkzeuge. Sie hat ein eigenes Token,
eigene Rechte und ein eigenes Dokument: [AGENTS.md](AGENTS.md). Die App
benutzt sie nicht.

---

## GET /v1/health

```json
{
  "ok": true,
  "hostname": "desktop-nico",
  "backends": [
    { "backend": "ollama",   "reachable": true,  "version": "0.6.2", "message": null },
    { "backend": "lmstudio", "reachable": false, "version": null,    "message": "connection refused" }
  ]
}
```

Ein nicht erreichbares Backend ist **kein** HTTP-Fehler — `ok` bezieht sich nur auf das
Gateway selbst. So kann die App "Desktop an, LM Studio zu" korrekt anzeigen.

## GET /v1/models

Liefert installierte *und* geladene Modelle beider Backends in einer Liste.

**Jedes Feld, das fehlen kann, ist ein `Fact`-Objekt**, kein nackter Wert:

```json
{ "value": 9123456789, "certainty": "known", "note": null }
```

`certainty`: `known` (Wert liegt vor) | `unknown` (existiert grundsätzlich,
war aber nicht zu ermitteln) | `unsupported` (dieses Backend kennt die Angabe
nicht). Bei `unknown`/`unsupported` steht der Grund in `note` — die App zeigt
`—` mit antippbarer Begründung statt einer Null, die wie ein Messwert aussieht.

```json
{
  "models": [
    {
      "id": "qwen2.5-coder:14b",
      "label": "qwen2.5-coder:14b",
      "backend": "ollama",
      "state": "loaded",
      "kind": "llm",
      "family":         { "value": "qwen2",  "certainty": "known", "note": null },
      "parameter_size": { "value": "14.8B",  "certainty": "known", "note": null },
      "quantization":   { "value": "Q4_K_M", "certainty": "known", "note": null },
      "disk_bytes":     { "value": 9123456789, "certainty": "known", "note": null },
      "vram_bytes":     { "value": 8734567890, "certainty": "known", "note": null },
      "vram_fraction":  { "value": 0.9573, "certainty": "known", "note": null },
      "context_length": { "value": 32768, "certainty": "known", "note": null },
      "loaded_context_length": { "value": 8192, "certainty": "known", "note": null },
      "unloads_at":     { "value": "2026-09-03T18:42:11Z", "certainty": "known", "note": null },
      "vision":         { "value": false, "certainty": "known", "note": null },
      "tools":          { "value": true,  "certainty": "known", "note": null },
      "thinking":       { "value": false, "certainty": "known", "note": null },
      "error": null
    }
  ],
  "errors": [
    { "backend": "lmstudio", "message": "/api/v0/models fehlgeschlagen: connection refused" }
  ]
}
```

`state`: `loaded` | `loading` | `unloading` | `not_loaded` | `error`
`kind`: `llm` | `vlm` | `embedding` | `unknown`

Ein ausgefallenes Backend blockiert die Antwort nicht: es erscheint in
`errors`, die Modelle des anderen Backends kommen trotzdem.

`vram_fraction` ist der Anteil des Modells, der wirklich auf der GPU liegt.
Ein Wert deutlich unter 1 erklärt, warum ein geladenes Modell zäh antwortet.

`thinking` sagt, ob das Modell Denkschritte erzeugt — siehe `/v1/chat`.

Herkunft der Zustände:

| Backend  | geladen                                   | installiert            | Ablauf                        |
|----------|-------------------------------------------|------------------------|-------------------------------|
| Ollama   | `/api/ps` (mit `size_vram`)               | `/api/tags`            | `expires_at` aus `/api/ps`    |
| LM Studio| `/api/v0/models` → `state: "loaded"`      | dieselbe Route         | nicht über die API verfügbar  |

## POST /v1/models/unload

```json
{ "backend": "ollama", "model": "qwen2.5-coder:14b" }
```

Ollama: Chat-Request mit `keep_alive: 0`. LM Studio: `POST /api/v0/models/unload`.
Antwort: `202` mit `{ "state": "unloading" }`.

## POST /v1/models/pin

Gleicher Body. Hält das Modell im Speicher (Ollama `keep_alive: -1`,
LM Studio TTL deaktivieren). Antwort: `{ "state": "loaded", "unloads_at": null }`.

## POST /v1/chat  → `text/event-stream`

```json
{
  "backend": "ollama",
  "model": "gemma4:e4b",
  "messages": [ { "role": "user", "content": "Warum ist der Himmel blau?", "images": [] } ],
  "temperature": 0.7,
  "max_tokens": null,
  "think": null
}
```

`images` sind base64-kodiert, ohne Data-URL-Prefix.

`think` steuert die Denkschritte: `null` heißt, das Gateway entscheidet anhand
der `thinking`-Fähigkeit des Modells. Das ist nicht optional — **Ollama liefert
`thinking` nur, wenn es angefordert wird**, und ein Reasoning-Modell antwortet
sonst mit dauerhaft leerem `content`.

Events (jeweils eine `data:`-Zeile):

```
data: {"type":"status","state":"accepted","note":null}
data: {"type":"status","state":"loading_model","note":"Modell ist nicht im Speicher und wird geladen"}
data: {"type":"status","state":"processing_prompt","note":null}
data: {"type":"reasoning","text":"Der Nutzer fragt nach "}
data: {"type":"delta","text":"Weil "}
data: {"type":"heartbeat"}
data: {"type":"done","metrics":{ … }}
```

| Typ | Bedeutung |
|---|---|
| `status`  | Phasenwechsel: `accepted`, `loading_model`, `processing_prompt`, `generating` |
| `reasoning` | Denkschritt. Gehört **nicht** in die Antwort und nicht in den nächsten Prompt, wird aber angezeigt und persistiert |
| `delta`   | Stück des Antworttexts |
| `heartbeat` | Lebenszeichen alle 10 s Stille — trennt "rechnet noch" von "Verbindung tot" |
| `done`    | Abschluss mit `metrics` |
| `error`   | Fehler als Event, nicht als abgebrochene Verbindung, damit die App den Grund zeigen kann |

`metrics` enthält ausschließlich `Fact`-Objekte:

```json
{
  "type": "done",
  "metrics": {
    "total_ms":                { "value": 4210.5, "certainty": "known", "note": null },
    "load_ms":                 { "value": 812.0,  "certainty": "known", "note": null },
    "time_to_first_token_ms":  { "value": 940.2,  "certainty": "known", "note": null },
    "prompt_tokens":           { "value": 184, "certainty": "known", "note": null },
    "completion_tokens":       { "value": 512, "certainty": "known", "note": null },
    "tokens_per_second":       { "value": 43.7, "certainty": "known", "note": null },
    "stop_reason":             { "value": "stop", "certainty": "known", "note": null }
  }
}
```

Fehler mitten im Stream:

```
data: {"type":"error","message":"model failed to load: not enough VRAM"}
```

Das Gateway übersetzt intern:
Ollama `POST /api/chat` (NDJSON, `message.thinking` → `reasoning`) bzw.
LM Studio `POST /api/v0/chat/completions` (OpenAI-SSE,
`delta.reasoning_content` → `reasoning`).

## WS /v1/telemetry?token=…

Ein Sample pro Sekunde. Auch hier ist jeder Messwert ein `Fact`:

```json
{
  "at": "2026-09-03T18:40:02Z",
  "cpu_percent":     { "value": 23.5, "certainty": "known", "note": null },
  "ram_used_bytes":  { "value": 21400000000, "certainty": "known", "note": null },
  "ram_total_bytes": { "value": 68719476736, "certainty": "known", "note": null },
  "gpus": [
    {
      "name": "Radeon RX 7900 XTX",
      "vendor": "amd",
      "source": "rocm-smi",
      "util_percent":    { "value": 78.0, "certainty": "known", "note": null },
      "vram_used_bytes": { "value": 19300000000, "certainty": "known", "note": null },
      "vram_total_bytes":{ "value": 25757220864, "certainty": "known", "note": null },
      "temp_c":          { "value": 61.0, "certainty": "known", "note": null },
      "power_watts":     { "value": null, "certainty": "unknown",
                           "note": "Leistungsaufnahme nicht ausgelesen" }
    }
  ],
  "gpu_note": null
}
```

`source` nennt die Quelle, aus der die Werte stammen: `rocm-smi`,
`amdgpu_top` oder `nvidia-smi`. Die Quellen werden in dieser Reihenfolge
probiert; die erste, die trägt, wird gemerkt.

**Alle GPU-Felder außer `name`, `vendor` und `source` können `unknown` sein.**
Je nach Treiberstand fehlen einzelne Werte. Die App zeigt sie als `—` mit
Begründung an statt als `0` — sonst sieht eine nicht auslesbare Auslastung wie
eine Idle-GPU aus.

Konnte überhaupt keine GPU gelesen werden, bleibt `gpus` leer und `gpu_note`
nennt alle gescheiterten Versuche mit Grund.

---

## Setup

```bash
flutter create --platforms=android,windows --org de.nicolas .
flutter pub get
flutter run -d windows
```

`flutter create` legt nur die Plattformordner an und fasst `lib/` nicht an.
Es erzeugt allerdings ein `test/widget_test.dart` für eine Beispiel-App, das
gegen diesen Baum nicht kompiliert — löschen.
