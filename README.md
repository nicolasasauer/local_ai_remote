# Local AI Remote

Fernzugriff auf lokal laufende LLMs (Ollama und LM Studio) über Tailscale —
mit Chat, Modellverwaltung und Systemtelemetrie. Flutter-App für Android und
Windows, dazu ein Python-Gateway auf dem Desktop.

```
┌── Android / Windows ──┐        Tailnet         ┌──── Desktop ──────────────┐
│  Flutter-App          │  HTTPS + Bearer-Token  │  Gateway (FastAPI)        │
│  SQLite-Verlauf       │ ─────────────────────► │   ├─ Ollama   :11434      │
│  Telemetrie-Ansicht   │ ◄───── SSE / WS ────── │   ├─ LM Studio :1234      │
└───────────────────────┘                        │   └─ psutil + GPU-Probes  │
                                                 └───────────────────────────┘
```

## Warum ein Gateway?

Ollama und LM Studio sind bereits HTTP-Server, für reinen Chat bräuchte man
nichts weiter. Das Gateway macht drei Dinge, die die Backends nicht können:
beide auf ein gemeinsames Schema normalisieren, CPU/RAM/GPU liefern, und eine
Auth-Schicht vor Server setzen, die selbst keine haben.

## Einrichtung

**Desktop**

```bash
cd gateway
pip install -r requirements.txt
cp .env.example .env          # Token setzen
python -m gateway.main        # lauscht auf 127.0.0.1:8765
tailscale serve --bg 8765     # HTTPS nach draußen ins Tailnet
```

Ollama braucht keine Sonderbehandlung, solange das Gateway lokal läuft.
LM Studio muss laufen (`lms server start` oder GUI mit aktivem Server).

**App**

```bash
cd app
flutter create --platforms=android,windows --org de.nicolas .
flutter pub get
flutter run -d windows
```

Die Plattformordner (`android/`, `windows/`) liegen bewusst nicht im Repo —
`flutter create` legt sie an, ohne die vorhandenen `lib/`-Dateien anzufassen.
In den Einstellungen dann die `tailscale serve`-URL und den Token eintragen.

## Aufbau

| Pfad | Inhalt |
|---|---|
| `gateway/backends/` | Adapter für Ollama und LM Studio |
| `gateway/telemetry.py` | CPU/RAM per psutil, GPU per rocm-smi / amdgpu_top / nvidia-smi |
| `app/lib/src/models/` | Datenmodelle inkl. `Fact` |
| `app/lib/src/data/` | SQLite-Store, HTTP-Client, Token-Schätzung |
| `app/lib/src/chat/` | Zustandsmaschine des Sendevorgangs, Kontextverdichtung |
| `app/lib/src/ui/` | Oberfläche |
| `API_CONTRACT.md` | Schnittstelle zwischen beiden Hälften |

## Leitgedanken

**Nichts erfinden.** Jeder Wert, der fehlen kann, reist als `Fact` mit
Sicherheitsgrad und Begründung. Die App zeigt `—` mit antippbarem Grund statt
einer Null, die wie ein Messwert aussieht.

**Die Datenbank ist die Wahrheit.** Die Frage wird persistiert, bevor der
Request rausgeht; die Antwort wird während des Streams alle 300 ms
fortgeschrieben. Beim Start werden hängengebliebene Antworten als
`interrupted` markiert — halber Text bleibt sichtbar, mit Knopf zum
Neugenerieren.

**Der Sendevorgang ist sichtbar.** `queued → connecting → accepted →
loading_model → processing_prompt → generating`, dazu Heartbeats alle 10 s und
ein Watchdog nach 25 s Stille. Kein erfundener Fortschrittsbalken, aber auch
kein stilles Warten.

**Kontextverdichtung ist optional und umkehrbar.** Zusammengefasst wird nur,
was gesendet wird; die Originale bleiben in SQLite.

## Stand

Der Code ist vollständig, aber noch nicht gegen echte Server gelaufen. Vor dem
ersten Start erwarten dich vermutlich:

- `flutter analyze` findet Kleinigkeiten (fehlende Imports, Typen an den
  Rändern) — der Baum wurde ohne Flutter-SDK geschrieben
- das JSON-Schema von `amdgpu_top` variiert zwischen Versionen; einmal
  `amdgpu_top --json --single` laufen lassen und `_probe_amdgpu_top()` abgleichen
- Entladen bei LM Studio geht nur über die CLI (`lms`), das Gateway meldet
  sonst `501` mit Begründung

## Repo anlegen

```bash
cd local_ai_remote
git init
git add .
git commit -m "Gateway und Flutter-App"
```
