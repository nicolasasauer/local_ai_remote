# Local AI Gateway

Ein Prozess auf dem Desktop, der Ollama und LM Studio auf ein gemeinsames
Schema normalisiert und zusaetzlich Systemtelemetrie liefert.

## Start

```bash
pip install -r requirements.txt
set GATEWAY_TOKEN=ein-langes-zufaelliges-geheimnis     # Windows: set, Linux: export
python -m gateway.main
```

Erreichbar auf `http://127.0.0.1:8765`. Das Gateway bindet absichtlich nur
lokal — nach draussen geht es ausschliesslich über Tailscale:

```bash
tailscale serve --bg 8765
tailscale serve status
```

Damit bekommst du HTTPS mit gültigem Zertifikat auf dem Tailnet-Hostnamen. Die
App trägt dann `https://desktop-nico.<tailnet>.ts.net` als Basis-URL ein.

## Routen

| Route | Zweck |
|---|---|
| `GET /v1/health` | Gateway + Erreichbarkeit beider Backends |
| `GET /v1/models` | Alle Modelle, normalisiert, mit Ladezustand |
| `POST /v1/models/pin` | Modell im Speicher halten |
| `POST /v1/models/unload` | Modell sofort entladen |
| `POST /v1/chat` | Chat als SSE-Stream |
| `WS /v1/telemetry` | CPU/RAM/GPU, ein Sample pro Sekunde |

## Das Fact-Prinzip

Jedes Feld, das je nach Backend oder Version fehlen kann, kommt als Objekt:

```json
"vram_bytes": { "value": 8734567890, "certainty": "known", "note": null }
"unloads_at": { "value": null, "certainty": "unsupported",
                "note": "LM Studio gibt den Auto-Unload-Timer nicht heraus" }
"util_percent": { "value": null, "certainty": "unknown",
                  "note": "Graphics-Pipe-Wert nicht in der Ausgabe" }
```

`unknown` heisst "existiert, konnten wir aber nicht ermitteln", `unsupported`
heisst "gibt es bei diesem Backend nicht". Die App zeigt beides als `—` mit
antippbarer Begründung — nie als `0`.

## AMD-Telemetrie

Die GPU-Quellen werden in dieser Reihenfolge probiert und die erste
funktionierende gemerkt: `rocm-smi` (Linux mit ROCm), `amdgpu_top` (Linux und
Windows), `nvidia-smi` (falls du mal wechselst). Schlägt alles fehl, kommt
`gpus: []` plus `gpu_note` mit allen Fehlermeldungen — dann sieht du in der App,
*warum* nichts da ist.

Für Windows ist `amdgpu_top` der realistische Weg; die Releases liegen auf
GitHub, die Exe muss im PATH liegen. Ohne das bleiben CPU und RAM trotzdem
vollständig nutzbar.

Ungetestet ist hier vor allem das JSON-Schema von `amdgpu_top` — die Feldnamen
haben sich zwischen Versionen geändert. Einmal `amdgpu_top --json --single`
laufen lassen und die Ausgabe abgleichen, dann passt `_probe_amdgpu_top()`.

## Autostart unter Windows

Als Aufgabe im Taskplaner, Trigger "Bei Anmeldung", Programm `pythonw.exe` mit
Argument `-m gateway.main` und Arbeitsverzeichnis auf diesen Ordner. `pythonw`
statt `python`, damit kein Konsolenfenster offen bleibt. Ollama läuft unter
Windows ohnehin als Dienst; LM Studio braucht `lms server start`.

## Entladen bei LM Studio

Dafür gibt es keinen REST-Endpunkt. Das Gateway ruft die CLI (`lms unload`) und
antwortet mit `501` und Begründung, wenn `lms` nicht im PATH liegt. Die App
deaktiviert den Button dann mit genau dieser Meldung als Tooltip.
