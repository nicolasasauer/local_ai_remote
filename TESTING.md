# Tests

Zwei Ebenen: automatisiert läuft, was ohne Hardware prüfbar ist. Alles, was
echte Modelle, ein echtes Gerät oder einen echten Netzabriss braucht, steht als
Szenarienliste unten und wird von Hand gefahren.

## Automatisiert

```bash
python -m pytest gateway/tests -q     # Gateway, ohne laufende Backends
cd app && flutter test                # App, ohne Gerät
```

Beide laufen offline: die Backends sind im Gateway-Test durch Attrappen
ersetzt, die App-Tests nutzen eine SQLite-Datenbank im Arbeitsspeicher.

### Was abgedeckt ist

| Datei | Prüft |
|---|---|
| `gateway/tests/test_gateway.py` | Auth (401 ohne/mit falschem Token, WebSocket), `.env`-Laden und Fail-Fast bei leerem oder kurzem Token, `reasoning` als eigener Event-Typ, `think`-Durchreichung, ausgefallenes Backend blockiert die Modellliste nicht, `Fact`-Lücken tragen eine Begründung |
| `app/test/chat_store_test.dart` | Umbenennen und Modellwechsel lassen den Verlauf stehen, Löschen räumt Nachrichten mit ab, `recoverInterrupted` markiert hängengebliebene Antworten, Denkschritte werden getrennt vom Antworttext persistiert |

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
