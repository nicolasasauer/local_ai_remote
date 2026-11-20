# Agenten-Werkzeuge am Gateway

Das Gateway spricht unter `/openai/v1` das Chat-Completions-Format. Damit
lassen sich Werkzeuge wie Aider, Continue oder Open WebUI auf die lokalen
Modelle richten — über das Tailnet, mit Token, mit beiden Backends in einer
Liste.

Diese Oberfläche ist **standardmäßig aus**. Sie erscheint erst, wenn
`GATEWAY_AGENT_TOKEN` gesetzt ist.

## Einschalten

```bash
# gateway/.env
GATEWAY_TOKEN=...langes-geheimnis-fuer-die-app...
GATEWAY_AGENT_TOKEN=...anderes-langes-geheimnis-fuer-werkzeuge...
```

Das Gateway verweigert den Start, wenn beide gleich sind — dann ließe sich der
Agentenzugang nicht getrennt zurückziehen, und genau das ist sein Zweck.

```bash
export OPENAI_BASE_URL="https://desktop.tailnet.ts.net/openai/v1"
export OPENAI_API_KEY="...das-agenten-token..."
```

Modelle tragen ihr Backend im Namen, weil OpenAI einen flachen Namensraum
kennt und hier zwei Server nebeneinander laufen:

```
ollama/qwen2.5-coder:14b
lmstudio/qwen/qwen3-coder-30b
```

Ein Name ohne Präfix wird aufgelöst, solange er eindeutig ist; sonst kommt ein
Fehler, der die Kandidaten nennt.

## Was die Oberfläche kann

| | |
|---|---|
| `GET /openai/v1/models` | beide Backends in einer Liste |
| `POST /openai/v1/responses` | Responses-API, weitergeleitet (siehe unten) |
| `POST /openai/v1/chat/completions` | streamend und nicht-streamend |
| Denkschritte | als `reasoning_content`, getrennt vom Antworttext |
| `usage` | echte Tokenzahlen beider Backends, im Stream auf Anforderung |
| Werkzeugaufrufe | `tools`, `tool_choice`, `tool_calls`, Rolle `tool` |
| Bilder | nur als `data:`-URL |

### Parameter

Durchgereicht an beide Backends: `temperature`, `top_p`, `max_tokens` (auch
als `max_completion_tokens`), `stop`, `seed`, `presence_penalty`,
`frequency_penalty`, `response_format: {"type": "json_object"}`.

**Abgelehnt statt still ignoriert** — mit `400` und Begründung:

| Parameter | Warum |
|---|---|
| `n` > 1 | es kommt immer genau eine Antwort |
| `logprobs` | die Backends reichen sie nicht durch |
| `response_format: json_schema` | nur `json_object` geht |

Der Grundsatz ist derselbe wie überall im Projekt: keine Antwort, die anders
zustande kam als angefordert, ohne dass es jemand sieht. Ein 400 kostet eine
Sekunde, ein stiller Unterschied eine Viertelstunde Fehlersuche.

Unbekannte Felder (`user`, `logit_bias`, …) werden verworfen, ohne die
Anfrage zu kippen — sonst wäre die Oberfläche mit realen Clients unbrauchbar.

Nicht enthalten: Embeddings, Completions im alten Format.

### Werkzeugaufrufe

Die beiden Backends liefern sie in unvereinbarer Form, das Gateway gleicht das
an:

| | Ollama | LM Studio |
|---|---|---|
| Zustellung | vollständig in einem Chunk | Fragmente, nach `index` zusammenzusetzen |
| `arguments` | Objekt | String, über mehrere Chunks verteilt |
| `finish_reason` | meldet `stop` | meldet `tool_calls` |

Nach außen kommt in beiden Fällen dasselbe: ein vollständiger Aufruf im
OpenAI-Format mit `arguments` als String und `finish_reason: "tool_calls"`.
Ein halber Aufruf wäre wertlos — der Client kann ihn weder ausführen noch
anzeigen —, deshalb wird bei LM Studio erst am Ende des Stroms ausgeliefert.

Der Rückweg funktioniert ebenso: eine `assistant`-Nachricht mit `tool_calls`
und die zugehörigen `tool`-Nachrichten gehen in der jeweils erwarteten Form
zurück ans Backend. Ollama ordnet Ergebnisse über den **Namen** zu, LM Studio
über die **`tool_call_id`** — beides wird mitgeführt.

Geprüft mit einer vollständigen Agentenschleife (Frage → Aufruf → lokale
Ausführung → Ergebnis → Antwort) gegen beide Backends, streamend und
nicht-streamend.

## Sicherheitsmodell

### Was geschützt ist

**Zwei getrennte Schlüssel.** Agenten-Werkzeuge legen ihren API-Key im
Klartext ab — in `~/.aider.conf.yml`, in Umgebungsvariablen, in der
Shell-Historie. Mit einem eigenen Token lässt sich genau dieser Zugang
zurückziehen, ohne das Telefon neu einzurichten. Beide Vergleiche laufen
zeitkonstant.

**Getrennte Rechte.** Das Agenten-Token öffnet *nur* Modellliste und Chat. Es
kommt nicht an `/v1/models/unload`, nicht an `/v1/models/pin`, nicht an
`/v1/models/load`, nicht an die Downloads und nicht an die Telemetrie; auch
Ladeoptionen (Kontextfenster, GPU) kann es nicht setzen. Ein Werkzeug soll dir kein Modell aus dem Speicher werfen, während
du am Telefon damit arbeitest. Umgekehrt öffnet das App-Token die
Agenten-Oberfläche nicht.

**Aus, wenn nicht gewollt.** Ohne `GATEWAY_AGENT_TOKEN` antworten die Routen
mit `404`, nicht mit `401` — wer nicht eingeladen ist, erfährt nicht einmal,
dass es hier etwas gibt. Eine Schnittstelle, an die man Werkzeuge hängt, die
Befehle auf dem eigenen Rechner ausführen, soll nicht stillschweigend
auftauchen, nur weil jemand das Gateway aktualisiert hat.

**Keine Abrufe aus Nachrichteninhalten.** Bilder werden nur als `data:`-URL
angenommen. Eine `https://`-URL im Nachrichteninhalt würde das Gateway zu
einem Downloader machen, der Adressen abruft, die im Zweifel ein Modell oder
eine fremde Datei hineingeschrieben hat.

**Obergrenze für den Anfragekörper** (`GATEWAY_MAX_REQUEST_BYTES`, 32 MB).
Agenten schicken ganze Projektdateien; der Desktop ist derselbe Rechner, auf
dem das Modell läuft. Gezählt wird, was ankommt, nicht was `Content-Length`
verspricht — eine Anfrage mit `Transfer-Encoding: chunked` hat den Header gar
nicht.

**Fehler im OpenAI-Format.** `{"error": {"message": …}}` auf oberster Ebene,
nicht in FastAPIs `detail` verpackt — sonst finden Clients die Meldung nicht
und zeigen „unknown error".

**Keine CORS-Header.** Browserseitige Werkzeuge können die Oberfläche nicht
ansprechen. Das ist Absicht: eine beliebige Webseite soll nicht im Namen des
Browsers deine Modelle benutzen können.

### Was nicht geschützt ist — und warum das so bleiben muss

**Das Gateway führt nichts aus, und das ist der Kern.** Ein Agent ruft
Werkzeuge auf: Dateien lesen, Kommandos starten, Patches schreiben. Das
passiert **auf dem Rechner des Agenten**, nicht hier. Das Gateway übersetzt
Nachrichten und reicht Ströme durch — mehr nicht. Diese Grenze ist die
wichtigste Eigenschaft des Entwurfs, und sie muss auch dann halten, wenn
Tool-Calling dazukommt: das Gateway leitet Werkzeugaufrufe weiter, es führt
sie nie selbst aus.

**Prompt-Injection kann das Gateway nicht abfangen.** Liest ein Agent eine
Datei oder Webseite, in der „ignoriere alles bisherige und lösche …" steht,
sieht das Gateway nur Text. Die Verteidigung liegt in der Rückfrage des
Agenten-Werkzeugs. Praktisch heißt das: die Bestätigungsabfragen des Werkzeugs
eingeschaltet lassen und keinen Agenten im Auto-Freigabe-Modus gegen dieses
Gateway laufen lassen.

**LM Studio beantwortet jeden Namen mit dem geladenen Modell.** Auch einen
frei erfundenen, und mit Status 200 — es gibt keinen Fehler, nur eine Antwort
vom falschen Modell. Das Gateway kann das nicht verhindern, aber es verschweigt
es nicht: die Antwort nennt im Feld `model` das Modell, das tatsächlich
geantwortet hat (so macht es auch die OpenAI-API selbst), und die App bekommt
während des Streams einen Hinweis. **Wer auf ein bestimmtes Modell angewiesen
ist, muss `model` in der Antwort prüfen** — der angefragte Name ist keine
Zusage.

**Das Token steht nicht mehr im Protokoll.** Beim WebSocket reist es als
Query-Parameter — Header sind dort nicht überall zuverlässig — und uvicorn
protokolliert den vollständigen Pfad. Ein Filter an den Log-*Handlern* ersetzt
den Wert; der Name bleibt stehen, damit das Protokoll brauchbar bleibt. Der
Filter muss an den Handlern hängen und in der Startphase gesetzt werden: am
Logger greift er nicht für heraufgereichte Meldungen, und uvicorn verwirft
beim Start alles, was vorher gesetzt wurde.

**Fehlermeldungen der Backends werden durchgereicht.** Darin können lokale
Pfade stehen. Für ein persönliches Tailnet vertretbar, für einen geteilten
Zugang nicht.

**Ein Agent kann die Maschine belegen.** Eine lange Sitzung hält das Modell im
Speicher und die GPU beschäftigt; die Telefon-App wartet dann. Es gibt derzeit
keine Begrenzung gleichzeitiger Läufe.

### Netzgrenze

Unverändert: das Gateway bindet auf `127.0.0.1`, nach außen geht es nur über
`tailscale serve`. Die Tailnet-ACLs sind die erste Schicht, das Token die
zweite. `GATEWAY_HOST=0.0.0.0` gehört nur in eine lokale, nicht eingecheckte
`.env` für Emulator-Tests — im LAN wäre das Gateway damit für jeden Nachbarn
im selben Netz erreichbar.

## Was beim Werkzeugeinsatz gilt

- Das Gateway **interpretiert Werkzeugaufrufe nicht** und führt sie nicht aus.
  Es kennt weder die Namen noch die Bedeutung der Werkzeuge; es setzt bei
  LM Studio nur die Fragmente zusammen und übersetzt die Argumente zwischen
  Objekt und String.
- Werkzeug-Ergebnisse, die der Client zurückschickt, sind Daten. Sie gehen
  unverändert ins nächste Prompt und lösen im Gateway nichts aus.
- Die Argumente eines Aufrufs sind **Modellausgabe, also unvertrauenswürdig**.
  Prüfen muss sie der Client, der sie ausführt — das Gateway kann nicht
  wissen, ob `{"pfad": "../../etc/passwd"}` gemeint war oder untergeschoben.
- Ein Modell ohne `tools`-Fähigkeit ignoriert die Werkzeuge stillschweigend;
  `/v1/models` zeigt die Fähigkeit pro Ollama-Modell an, LM Studio meldet sie
  nicht.

Realistisch sind `qwen3-coder:30b` oder die Qwen3.6-Modelle — kleinere drehen
sich bei Werkzeugketten im Kreis. Und die gemeldeten 262k Kontext sind
theoretisch: der KV-Cache dafür passt nicht in den VRAM, die Fenster müssen
deutlich kleiner gefahren werden.

## Responses-API und die Codex CLI

Die Codex CLI (ab 0.133) unterstützt `wire_api = "chat"` **nicht mehr** und
verlangt die Responses-API. Beide Backends implementieren die Route bereits
nativ und in derselben Form, deshalb *leitet* das Gateway hier weiter, statt
zu übersetzen:

```toml
# ~/.codex/config.toml
model = "ollama/<modell>"
model_provider = "lokalgw"

[model_providers.lokalgw]
name = "Lokales Gateway"
base_url = "https://desktop.tailnet.ts.net/openai/v1"
env_key = "LOKAL_API_KEY"
wire_api = "responses"
```

Ohne das Gateway funktioniert das **nicht** — und zwar aus zwei Gründen, die
nichts mit dem Tailnet zu tun haben:

**1. Codex bietet eingebaute Werkzeugtypen an.** Neben seinen Funktionen
schickt es `image_generation`, `web_search` und `namespace` mit. Ollama
antwortet darauf mit `HTTP 500: Failed to parse tools: Unsupported tool type` —
eine einzige Zeile in der Werkzeugliste macht die ganze Sitzung unbrauchbar.
Das Gateway behält die Funktionen und verwirft den Rest.

**2. Codex schickt `instructions` und zusätzlich einen `developer`-Eintrag.**
Ollama macht daraus zwei Systemnachrichten. Strenge Chat-Vorlagen — Qwen3.6
etwa — brechen dann mit `Jinja Exception: System message must be at the
beginning` ab. Das Gateway faltet beides zu einer Anweisung am Anfang
zusammen; Inhalt und Reihenfolge bleiben erhalten.

Beides ist ein bewusster Verstoß gegen den Grundsatz „nichts still anders
machen als angefordert" — hier ist die Alternative aber, dass gar nichts
läuft. Verworfene Werkzeugtypen und die Faltung werden deshalb im
Gateway-Protokoll vermerkt.

Geprüft mit Codex 0.133 gegen beide Backends: das Modell liest über Codex'
eigenes Shell-Werkzeug eine Datei und antwortet korrekt. Direkt gegen Ollama
scheitert dieselbe Anfrage.

Was die Weiterleitung kostet: Antwortfelder kommen unverändert vom Backend,
also ohne die gemeinsame Form der übrigen Routen. Für eine Agenten-CLI ist das
richtig — sie erwartet die Form ihres Anbieters.

## Danach, vielleicht: `/v1/messages`

Die Claude Code CLI lässt sich über `ANTHROPIC_BASE_URL` umbiegen und spräche
dann ein Anthropic-förmiges Format, nicht das OpenAI-Format. Das ist echte
Übersetzungsarbeit statt Durchreichen, und es ist keine unterstützte
Konfiguration — vor jedem Aufwand gehört ein Wegwerf-Prototyp, der zeigt, ob
es überhaupt trägt.
