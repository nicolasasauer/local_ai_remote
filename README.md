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
| `AGENTS.md` | OpenAI-kompatible Oberfläche und ihr Sicherheitsmodell |
| `TESTING.md` | was automatisiert läuft, was von Hand geprüft wird |

## Agenten-Werkzeuge

Unter `/openai/v1` spricht das Gateway zusätzlich Chat-Completions **und** die
Responses-API, jeweils mit Werkzeugaufrufen. Damit laufen Agenten-Werkzeuge
über das Tailnet gegen die lokalen Modelle — die Codex CLI ist gegen beide
Backends geprüft. Die Oberfläche ist standardmäßig aus und braucht ein
**eigenes** Token; Details und Sicherheitsmodell in [AGENTS.md](AGENTS.md).

## Recherche

Das Gateway kann für die App im Web suchen und Seiten abrufen — die **einzige**
Stelle, an der es etwas ausführt. Standardmäßig aus (`GATEWAY_RESEARCH=1`),
und nichts läuft ohne Freigabe: das Modell *schlägt* einen Aufruf vor, in der
App wird er einzeln bestätigt.

Der Werkzeugkatalog gehört dem Gateway. Die App schaltet Recherche nur ein
oder aus; sie kann keine eigenen Werkzeuge definieren, die das Gateway dann
ausführen würde.

Der Seitenabruf prüft die **aufgelöste** Adresse, nicht den Namen, und
verfolgt Umleitungen selbst. Blockiert sind Loopback, private Netze,
Link-Local, Cloud-Metadaten — und ausdrücklich `100.64.0.0/10`, weil Python
Tailscale-Adressen nicht als privat kennt und dort dieses Gateway selbst
steht.

Eine Suchquelle muss eingerichtet werden (`searxng` oder `brave`); ohne sie
bietet das Gateway nur den Seitenabruf an. Ein lokales SearXNG passt am besten
zum Rest des Projekts.

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

Beide Hälften laufen gegen echte Server: Ollama 0.33 und LM Studio, Chat mit
Denkschritten, Telemetrie, Modellverwaltung, geprüft auf dem Android-Emulator
und unter Windows. `flutter analyze` ist sauber, Tests siehe
[TESTING.md](TESTING.md).

Offen:

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
