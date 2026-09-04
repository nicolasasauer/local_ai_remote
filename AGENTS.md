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
| `POST /openai/v1/chat/completions` | streamend und nicht-streamend |
| Denkschritte | als `reasoning_content`, getrennt vom Antworttext |
| `usage` | echte Tokenzahlen beider Backends, im Stream auf Anforderung |
| Bilder | nur als `data:`-URL |

Nicht enthalten: Tool-Calling (siehe unten), Embeddings, Completions im alten
Format.

## Sicherheitsmodell

### Was geschützt ist

**Zwei getrennte Schlüssel.** Agenten-Werkzeuge legen ihren API-Key im
Klartext ab — in `~/.aider.conf.yml`, in Umgebungsvariablen, in der
Shell-Historie. Mit einem eigenen Token lässt sich genau dieser Zugang
zurückziehen, ohne das Telefon neu einzurichten. Beide Vergleiche laufen
zeitkonstant.

**Getrennte Rechte.** Das Agenten-Token öffnet *nur* Modellliste und Chat. Es
kommt nicht an `/v1/models/unload`, nicht an `/v1/models/pin`, nicht an die
Telemetrie. Ein Werkzeug soll dir kein Modell aus dem Speicher werfen, während
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
dem das Modell läuft.

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

## Nächster Schritt: Tool-Calling

Ohne Tool-Calling sind Werkzeuge nutzbar, die mit reinem Text arbeiten (Aider
etwa erzeugt Diffs im Antworttext). Agenten-CLIs, die Werkzeuge aufrufen,
brauchen mehr. Nötig wären:

1. `tools` und `tool_choice` in `ChatRequest`, durchgereicht an beide Backends
2. die Rolle `tool` und das Feld `tool_calls` in `ChatMessage`
3. ein Ereignistyp `ToolCall`, analog zum `Reasoning`-Kanal
4. Zusammensetzen der OpenAI-Fragmente: `tool_calls` kommen indiziert und
   stückweise, die Argumente über mehrere Chunks verteilt

Strukturell dieselbe Arbeit wie beim Denkschritt-Kanal, nur umfangreicher. Die
Sicherheitsregeln dabei:

- Das Gateway **interpretiert Werkzeugaufrufe nicht** und führt sie nicht aus.
  Es kennt weder die Namen noch die Bedeutung der Werkzeuge.
- Werkzeug-Ergebnisse, die der Client zurückschickt, sind Daten. Sie gehen
  unverändert ins nächste Prompt und lösen im Gateway nichts aus.
- Die Argumente eines Werkzeugaufrufs sind Modellausgabe, also unvertrauenswürdig.
  Prüfen muss sie der Client, der sie ausführt.
- Für Werkzeug-Ergebnisse gilt dieselbe Größengrenze wie für alles andere.

Realistisch sind dafür `qwen3-coder:30b` oder die Qwen3.6-Modelle — kleinere
drehen sich bei Werkzeugketten im Kreis. Und die gemeldeten 262k Kontext sind
theoretisch: der KV-Cache dafür passt nicht in den VRAM, die Fenster müssen
deutlich kleiner gefahren werden.

## Danach, vielleicht: `/v1/messages`

Die Claude Code CLI lässt sich über `ANTHROPIC_BASE_URL` umbiegen und spräche
dann ein Anthropic-förmiges Format, nicht das OpenAI-Format. Das ist echte
Übersetzungsarbeit statt Durchreichen, und es ist keine unterstützte
Konfiguration — vor jedem Aufwand gehört ein Wegwerf-Prototyp, der zeigt, ob
es überhaupt trägt.
