# Lokale Suchquelle

[SearXNG](https://docs.searxng.org/) fragt öffentliche Suchmaschinen ab und
gibt die Treffer gebündelt zurück. Es passt zum Rest des Projekts: die Suche
läuft auf demselben Rechner wie die Modelle, es braucht keinen API-Schlüssel,
und keine Anfrage trägt eine Kennung, die sich auf dich zurückführen lässt.

Ohne Suchquelle bietet das Gateway nur den Seitenabruf an — ein Werkzeug, das
an fehlender Konfiguration scheitert, kostet einen Zug und eine Freigabe für
nichts.

## Starten

`..\start.ps1` erledigt das mit. Von Hand:

```powershell
cd search
docker compose --env-file .env up -d
```

Die `.env` mit dem Instanz-Geheimnis legt das Startskript beim ersten Lauf an.
Von Hand:

```powershell
python -c "import secrets; print('SEARXNG_SECRET=' + secrets.token_hex(32))" | Set-Content .env -Encoding utf8
```

Dann im Gateway (`gateway/.env`):

```
GATEWAY_RESEARCH=1
GATEWAY_SEARCH_PROVIDER=searxng
GATEWAY_SEARXNG_URL=http://127.0.0.1:8888
```

## Prüfen

```powershell
curl "http://127.0.0.1:8888/search?q=test&format=json"
```

Kommt hier ein **403**, fehlt `json` in den `formats` der `settings.yml`. Das
ist die häufigste Stolperstelle: SearXNG liefert JSON standardmäßig **nicht**,
die Weboberfläche funktioniert dabei ganz normal weiter — der Fehler fällt
also erst auf, wenn das Gateway sucht.

## Beenden

```powershell
..\start.ps1 -StopSearch
```

## Warum die Adresse nicht geprüft wird

Der Seitenabruf des Gateways lehnt Adressen im lokalen Netz ab. Die Suchquelle
ist davon ausgenommen, und das ist Absicht: sie wird vom Betreiber
eingerichtet, nicht vom Modell gewählt. Der Unterschied ist der ganze Punkt —
`GATEWAY_SEARXNG_URL` steht in deiner `.env`, eine abzurufende Adresse steht
in einer Modellausgabe.

Die **Treffer** der Suche gehen dagegen wieder durch die volle Prüfung, sobald
das Modell einen davon abrufen möchte.
