# Tests

Zwei Ebenen: automatisiert läuft, was ohne Hardware prüfbar ist. Alles, was
echte Modelle, ein echtes Gerät oder einen echten Netzabriss braucht, steht als
Szenarienliste unten und wird von Hand gefahren.

## Automatisiert

```bash
python -m pytest gateway/tests -q     # Gateway, ohne laufende Backends
cd app && flutter test                # App, ohne Gerät
```

Die Adapter-Tests nutzen `httpx.MockTransport` und prüfen dabei auch, **was
das Gateway sendet** — nicht nur, wie es die Antwort liest. Zwei der bisher
gefundenen Fehler sassen genau dort: Ollama liefert Denkschritte nur auf
Anforderung, LM Studio Tokenzahlen nur auf Anforderung.

Beide laufen offline: die Backends sind im Gateway-Test durch Attrappen
ersetzt, die App-Tests nutzen eine SQLite-Datenbank im Arbeitsspeicher.

### Was abgedeckt ist

| Datei | Prüft |
|---|---|
| `gateway/tests/test_gateway.py` | Auth (401 ohne/mit falschem Token, WebSocket), `.env`-Laden und Fail-Fast bei leerem oder kurzem Token, Obergrenze des Anfragekörpers auch ohne `Content-Length` (chunked), `reasoning` als eigener Event-Typ, `think`-Durchreichung, ausgefallenes Backend blockiert die Modellliste nicht, `Fact`-Lücken tragen eine Begründung |
| `gateway/tests/test_telemetrie_verteiler.py` | einmal messen, an alle verteilen: zwei Zuhörer treiben den Leser nicht doppelt an, ohne Zuhörer wird nicht gemessen, ein langsamer Zuhörer bremst die anderen nicht |
| `gateway/tests/test_windows_gpu.py` | Auswertung der GPU-Zähler: Prozesse einer Engine addieren, über Engine-Arten das Maximum nehmen, die beiden Formen der Instanznamen, Groß-/Kleinschreibung der LUID. Der ctypes-Teil läuft nur unter Windows und ist entsprechend markiert |
| `gateway/tests/test_research.py` | die Absicherung des Seitenabrufs: interne Adressen, Tailnet, Umleitungen ins lokale Netz, mehrfache DNS-Antworten, DNS-Rebinding zwischen Prüfung und Abruf (verbunden wird mit der geprüften IP), Abschneiden beim Lesen statt nach dem Laden, fremde Schemata, Binärinhalte — und dass die App keine eigenen Werkzeuge vorgeben kann |
| `gateway/tests/test_responses.py` | die zwei Normalisierungen der Responses-API: eingebaute Werkzeugtypen fliegen raus, `developer`-Anweisungen werden in `instructions` gefaltet — ohne beides scheitert die Codex CLI mit HTTP 500 |
| `gateway/tests/test_tools.py` | Werkzeugaufrufe auf Adapter-Ebene: Ollamas Objekt-Argumente werden zum JSON-String, LM Studios Fragmente werden zusammengesetzt, `stop` wird zu `tool_calls`, und der Verlauf geht in der jeweils erwarteten Form zurück |
| `gateway/tests/test_backends.py` | was die Adapter tatsächlich senden und wie sie die Antwort lesen — `think` bei Ollama, `stream_options` bei LM Studio, Denkschritte getrennt vom Antworttext, Modellverwechslung |
| `app/test/gateway_client_test.dart` | SSE-Zerlegung, Denkschritte als eigener Ereignistyp, Fehler mitten im Stream, und dass ein Abbruch die Verbindung wirklich schliesst |
| `app/test/chat_store_test.dart` | Umbenennen und Modellwechsel lassen den Verlauf stehen, Löschen räumt Nachrichten mit ab, `recoverInterrupted` markiert hängengebliebene Antworten, Denkschritte werden getrennt vom Antworttext persistiert |

`gateway/tests/conftest.py` setzt vor jedem Test eine neutrale Konfiguration:
alles aus, nichts eingerichtet. Ohne das entscheidet die lokale `gateway/.env`
darüber, was ein Test vorfindet — wer Recherche eingeschaltet hat, sieht
andere Ergebnisse als die CI. Genau das ist dreimal passiert, bis der
Ausgangszustand erzwungen wurde.

Die beiden `upsertChat`-Tests sind gegen die alte Implementierung gegengeprüft:
mit `ConflictAlgorithm.replace` schlagen sie fehl (`Actual: []`), mit dem
UPSERT gehen sie durch. Ein Regressionstest, der den Fehler nicht fängt, wäre
wertlos.

### Was bewusst nicht abgedeckt ist

Widget- und Integrationstests der Oberfläche. Der Aufwand stünde bei einer
Ein-Personen-App in keinem Verhältnis; die Oberfläche wird über die Szenarien
unten geprüft. Ebenso ungetestet: die GPU-Probes in `telemetry.py` — sie hängen
an Treibern und Fremdprogrammen, die sich nicht sinnvoll nachbauen lassen.

## Von Hand: Emulator-Szenarien

Voraussetzung:

```bash
# Desktop
python -m gateway.main                      # GATEWAY_HOST=0.0.0.0 für den Emulator
# App
flutter emulators --launch Medium_Phone_API_36.1
cd app && flutter run -d emulator-5554
```

Der Emulator erreicht den Host unter `10.0.2.2`, die Adresse lautet also
`http://10.0.2.2:8765`. Reines HTTP geht nur im Debug-Build — Flutter setzt
dort `usesCleartextTraffic`. Im Release-Build braucht es die HTTPS-Adresse aus
`tailscale serve`.

| # | Szenario | Erwartung |
|---|---|---|
| 1 | Frage an ein Reasoning-Modell | Denkschritte laufen sichtbar mit, danach die Antwort; Metriken unter der Nachricht |
| 2 | Stopp mitten im Stream | Status `Abgebrochen`, Teiltext bleibt, **und die Generierung auf dem Desktop endet** (`llama-server` fällt auf 0 %) |
| 3 | Gateway während des Streams beenden | Teiltext bleibt, konkreter Grund statt „Timeout", Kopfzeile wechselt auf „derzeit nicht angeboten" |
| 4 | Gateway wieder starten | Modellliste und Telemetrie kommen von allein zurück |
| 5 | App während des Streams abschießen (`adb shell am force-stop`) | Nach Neustart: `App wurde beendet, während die Antwort lief`, halbe Antwort samt Denkschritten steht noch |
| 6 | Chat löschen, während der Stream läuft | Kein Absturz, keine verwaiste Generierung |
| 7 | Erste Frage in einem frischen Chat | Chat wird nach der Frage benannt **und die Frage bleibt sichtbar** |
| 8 | Modell mitten im Chat wechseln | Verlauf bleibt vollständig, Kontext wird neu geschätzt (`~` kehrt zurück) |
| 9 | Falscher Token in den Einstellungen | `401` mit lesbarer Meldung, keine leere Liste ohne Erklärung |

### Telemetrie mit zwei Zuhörern

Der Fall, der den Fehler aufgedeckt hat, und der einzige, in dem er sichtbar
wird. CPU- und GPU-Auslastung sind Differenzmessungen; mit **einem** Zuhörer
stimmten die Werte, mit **zweien** sprang die Anzeige zwischen dem echten Wert
und 0 %.

Zum Gegenprüfen: App verbinden, zusätzlich eine zweite Verbindung öffnen, und
beide Ströme gegen den Windows-Zähler halten — während echte Last läuft.

```powershell
Get-Counter "\GPU Engine(*)\Utilization Percentage" |
  ForEach-Object { $_.CounterSamples } |
  Group-Object { ($_.InstanceName -split "_engtype_")[-1] } |
  ForEach-Object { "{0,-14} {1,6:N1} %" -f $_.Name, (($_.Group | Measure-Object CookedValue -Sum).Sum) }
```

Erwartung: beide Zuhörer bekommen **identische** Werte, und die liegen im
Bereich des Zählers. Ein Sägezahn zwischen ~100 % und 0 % heißt, dass wieder
jede Verbindung selbst misst.

Der Task-Manager taugt als zweite Referenz: seine GPU-Anzeige ist ebenfalls
das Maximum über die Engine-Arten, nicht deren Summe.

### Recherche in der App

Braucht ein Modell mit `tools`-Fähigkeit und `GATEWAY_RESEARCH=1`.

| # | Schritt | Erwartung |
|---|---|---|
| 1 | „Im Web nachsehen dürfen" im Chat-Menü einschalten | bleibt pro Chat gesetzt |
| 2 | Nach etwas fragen, das einen Abruf braucht | Freigabekarte nennt **den konkreten Gegenstand**, nicht nur „Werkzeug ausführen"; Phase steht auf „Wartet auf Freigabe", kein Stopp-Knopf |
| 3 | Freigeben | „Seite abgerufen" mit sichtbarer Quelle, danach eine Antwort, die den Inhalt tatsächlich verwendet |
| 4 | Ablehnen | das Modell antwortet ohne die Recherche, statt es erneut zu versuchen |
| 5 | Abruf einer Tailnet-Adresse (`100.x`) erzwingen | `422` mit Begründung, kein Abruf |

Schritt 5 lässt sich ohne App prüfen:

```bash
curl -s -X POST http://127.0.0.1:8765/v1/research   -H "Authorization: Bearer $GATEWAY_TOKEN" -H "Content-Type: application/json"   -d '{"name":"fetch_url","arguments":"{\"url\": \"http://100.101.102.103/\"}"}'
```

### Release-Build auf einem echten Gerät

Der Release-Build verhält sich in zwei Punkten anders als der Debug-Build im
Emulator, und beide fallen erst auf dem Telefon auf:

| | Debug | Release |
|---|---|---|
| `INTERNET`-Berechtigung | von `flutter create` gesetzt | **nur wenn** `app/android/app/src/main/AndroidManifest.xml` sie enthält |
| Reines HTTP | geht | **geht nicht** — geprüft, direkt hintereinander gegen dasselbe Gateway |

Ohne die Berechtigung schlägt jeder Aufruf fehl und sieht aus wie „Gateway
nicht erreichbar". Deshalb ist dieses eine Manifest eingecheckt, während der
Rest von `android/` generiert bleibt — es überlebt ein erneutes
`flutter create`.

Für das Telefon heißt der zweite Punkt: `tailscale serve --bg 8765` ist
Pflicht, nicht Kür. Die Adresse aus `tailscale serve status` gehört in die
Einstellungen.

```powershell
flutter build apk --release
# Manifest gegenprüfen, bevor die APK auf ein Gerät geht:
Select-String -Path build\app\intermediates\merged_manifests\release\*\AndroidManifest.xml -Pattern "permission.INTERNET"
```

### Agentenschleife

Nicht automatisiert, weil sie ein echtes Modell mit `tools`-Fähigkeit braucht.
`gateway/tests/agentenschleife.py` fährt Frage → Werkzeugaufruf → lokale
Ausführung → Ergebnis → Antwort und meldet, ob die Schleife durchläuft. Das
Werkzeug wird im Skript ausgeführt, nicht im Gateway:

```bash
python gateway/tests/agentenschleife.py "ollama/<modell>"
python gateway/tests/agentenschleife.py "lmstudio/<modell>" --stream
```

Erwartung im ersten Zug: `finish_reason=tool_calls` und ein vollständiger
Aufruf mit lesbaren Argumenten. Im zweiten Zug eine Antwort, die das Ergebnis
tatsächlich verwendet.

Szenario 2, 7 und 8 haben je einen echten Fehler aufgedeckt — sie sind die
wichtigsten der Liste.

### Nützliche Handgriffe

```bash
adb -s emulator-5554 logcat -d -s flutter:* | grep "Unhandled Exception"
adb -s emulator-5554 exec-out screencap -p > shot.png
adb -s emulator-5554 shell am force-stop de.nicolas.local_ai_remote
```

Ob eine abgebrochene Anfrage den Desktop wirklich freigibt, zeigt am
verlässlichsten der Prozess selbst:

```bash
python -c "import psutil,time; p=[x for x in psutil.process_iter(['name']) if x.info['name']=='llama-server.exe'][0]; p.cpu_percent(); time.sleep(2); print(p.cpu_percent(), '%')"
```
