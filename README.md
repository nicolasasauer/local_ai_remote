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

```powershell
pip install -r gateway\requirements.txt
Copy-Item gateway\.env.example gateway\.env
# GATEWAY_TOKEN setzen:
python -c "import secrets; print(secrets.token_urlsafe(32))"

tailscale serve --bg 8765     # einmalig, HTTPS nach draußen ins Tailnet
.\start.ps1
```

`start.ps1` prüft der Reihe nach, was fehlt, startet auf Wunsch die lokale
Suchquelle und dann das Gateway im Vordergrund. Was nicht läuft, wird beim
Namen genannt statt in einer Fehlermeldung zu verschwinden:

```
Voraussetzungen
  [ok]   gateway\.env sieht brauchbar aus.
  [ok]   Python-Pakete vollstaendig.
Inferenz-Server
  [ok]   Ollama laeuft (Port 11434).
  [!]    LM Studio laeuft nicht - GUI starten oder: lms server start.
Suchquelle
  [ok]   SearXNG laeuft auf http://127.0.0.1:8888
```

Ein fehlendes Backend ist kein Abbruchgrund — das Gateway zeigt es als „nicht
erreichbar" an, das andere funktioniert weiter.

Ohne Skript geht es genauso von Hand:

```bash
python -m gateway.main        # lauscht auf 127.0.0.1:8765
```

Ollama braucht keine Sonderbehandlung, solange das Gateway lokal läuft.
LM Studio muss laufen (`lms server start` oder GUI mit aktivem Server).

**App**

Fertige Builds hängen unter
[*Releases*](https://github.com/nicolasasauer/local_ai_remote/releases) am
Repo: `lokal-ai-vX.Y.Z.apk` fürs Telefon, `lokal-ai-vX.Y.Z-windows.zip` für den
Desktop. In den Release-Notizen steht der SHA-256-Fingerabdruck des
Signaturzertifikats — gleich bleibt er nur, solange derselbe Schlüssel
signiert, und genau daran erkennt man eine echte APK aus diesem Repo. Das App
Bundle für Google Play (`.aab`) hängt nur am Workflow-Lauf (*Actions →
Lauf → Artifacts*), nicht am öffentlichen Release. Ein neues Release entsteht entweder mit einem Tag

```bash
git tag v0.1.0 && git push origin v0.1.0
```

oder ohne Tag unter *Actions → build → Run workflow* mit der Version im Feld
`release` — der Tag wird dann auf GitHub angelegt. Der `versionCode` kommt aus
der Laufnummer der Action und steigt damit von selbst, wie Google Play es
verlangt.

### Signierung mit eigenem Schlüssel

Releases werden mit einem eigenen **Upload-Schlüssel** signiert; ohne ihn
bricht der Release-Lauf ab, statt eine APK mit Debug-Schlüssel zu
veröffentlichen (die ließe sich nie als Update über eine signierte Version
installieren). Normale Läufe ohne Secrets — etwa Pull Requests aus Forks —
bauen weiter mit dem Debug-Schlüssel.

Schlüssel einmalig erzeugen und **sicher aufbewahren** (Passwortmanager) —
geht er verloren, kann man ihn bei Google Play zwar zurücksetzen lassen, aber
Sideload-Installationen lassen sich dann nur noch nach Deinstallation
aktualisieren:

```bash
keytool -genkeypair -v -keystore upload.jks -storetype PKCS12 \
  -keyalg RSA -keysize 4096 -validity 10000 -alias upload
base64 -w0 upload.jks > upload.jks.b64     # macOS: base64 -i upload.jks
```

Unter *Settings → Secrets and variables → Actions* anlegen:

| Secret | Inhalt |
|---|---|
| `ANDROID_KEYSTORE_BASE64` | Inhalt von `upload.jks.b64` |
| `ANDROID_KEYSTORE_PASSWORD` | Keystore-Passwort |
| `ANDROID_KEY_ALIAS` | `upload` (bzw. der gewählte Alias) |
| `ANDROID_KEY_PASSWORD` | Schlüsselpasswort — bei PKCS12 dasselbe, darf dann fehlen |
| `PLAY_SERVICE_ACCOUNT_JSON` | *optional*: JSON eines Dienstkontos mit Zugriff in der Play Console |

Mit `PLAY_SERVICE_ACCOUNT_JSON` lädt ein Release das App Bundle zusätzlich als
**Entwurf in die interne Testspur** hoch; freigegeben wird in der Play Console.
Den allerersten Upload einer App nimmt die Play-API nicht an — die erste
`.aab` aus dem Release also einmal von Hand hochladen. In der Play Console
*App-Signatur durch Google Play* aktiv lassen: Google signiert die
ausgelieferte App mit seinem eigenen Schlüssel, der Upload-Schlüssel oben
weist nur nach, dass der Upload von dir kommt.

Die Paket-ID ist `de.nicolas.local_ai_remote` (aus `flutter create --org
de.nicolas`) und lässt sich nach dem ersten Play-Upload nicht mehr ändern.

Lokal signiert `android/key.properties` (nicht eingecheckt):

```properties
storeFile=/pfad/zu/upload.jks
storePassword=...
keyAlias=upload
keyPassword=...
```

Eingebunden wird beides über `app/android/app/signing.gradle`; die CI hängt
an das von `flutter create` erzeugte Build-Skript nur eine `apply`-Zeile an.
Lokal dieselbe Zeile ans Ende von `android/app/build.gradle.kts` setzen:
`apply(from = "signing.gradle")`.

Selbst bauen:

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
| `gateway/telemetry.py` | CPU/RAM per psutil, GPU aus mehreren Quellen |
| `gateway/windows_gpu.py` | GPU unter Windows ohne Fremdwerkzeug (PDH + DXGI) |
| `app/lib/src/models/` | Datenmodelle inkl. `Fact` |
| `app/lib/src/data/` | SQLite-Store, HTTP-Client, Token-Schätzung |
| `app/lib/src/chat/` | Zustandsmaschine des Sendevorgangs, Kontextverdichtung |
| `app/lib/src/ui/` | Oberfläche |
| `app/assets/icon/` | Icon-Quelle, erzeugt von `app/tool/icon_erzeugen.py` |
| `search/` | lokale Suchquelle (SearXNG) als `docker compose` |
| `start.ps1` | prüft die Voraussetzungen und startet alles |
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

Verbunden wird mit **genau der geprüften IP**; der Name reist nur als `Host`
und per SNI mit, gegen ihn wird auch das Zertifikat geprüft. Löste der Abruf
den Namen selbst noch einmal auf, könnte ein Name mit kurzer Gültigkeit bei
der Prüfung öffentlich und beim Verbinden auf `127.0.0.1` zeigen
(DNS-Rebinding). Gelesen wird höchstens `GATEWAY_RESEARCH_MAX_BYTES` (2 MB);
eine Seite mit endlosem Körper wird abgeschnitten statt ganz geladen.

Für die Websuche braucht es eine Quelle. Ein lokales SearXNG liegt als
`docker compose` bei und passt am besten zum Rest des Projekts — siehe
[search/README.md](search/README.md). Ohne Quelle bietet das Gateway nur den
Seitenabruf an.

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
  `amdgpu_top --json --single` laufen lassen und `_probe_amdgpu_top()` abgleichen.
  Unter Windows braucht es das nicht — dort greifen die Leistungsindikatoren
- Entladen bei LM Studio geht nur über die CLI (`lms`), das Gateway meldet
  sonst `501` mit Begründung

## Repo anlegen

```bash
cd local_ai_remote
git init
git add .
git commit -m "Gateway und Flutter-App"
```
