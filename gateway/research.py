"""Recherche-Werkzeuge: Websuche und Seitenabruf.

Dies ist die **einzige** Stelle, an der das Gateway etwas im Auftrag einer
Anfrage ausfuehrt. Bisher galt: es uebersetzt und reicht durch, mehr nicht.
Diese Grenze wird hier bewusst verschoben, und deshalb so eng wie moeglich:

* Es gibt genau zwei Operationen - suchen und eine Seite abrufen. Keine
  Dateien, keine Kommandos, kein Schreiben.
* Der **Katalog gehoert dem Gateway**, nicht dem Aufrufer. Die App schaltet
  Recherche nur ein oder aus; sie kann keine eigenen Werkzeuge definieren, die
  das Gateway dann ausfuehrt.
* Ausgefuehrt wird erst auf ausdrueckliche, getrennte Anfrage. Das Modell
  *schlaegt* einen Aufruf vor, freigegeben wird er in der App.

Der Abruf ist der gefaehrliche Teil. Eine URL kann aus dem Modell stammen oder
aus einer Seite, die es vorher gelesen hat - beides ist nicht
vertrauenswuerdig. Ohne Pruefung waere das Gateway ein Werkzeug, mit dem sich
aus dem Internet heraus das lokale Netz und das Tailnet abklopfen laesst.
"""

from __future__ import annotations

import asyncio
import html
import ipaddress
import json
import re
import socket
from html.parser import HTMLParser
from typing import Any, Optional
from urllib.parse import urlparse

import httpx
from pydantic import BaseModel

from .config import CONFIG

# ---------------------------------------------------------------------------
# Werkzeugkatalog
# ---------------------------------------------------------------------------

#: Englische Namen, weil Modelle sie in dieser Form gelernt haben - die
#: Beschreibungen bleiben deutsch, sie sind fuer das Modell im Kontext.
WEB_SUCHE = "web_search"
SEITE_ABRUFEN = "fetch_url"


def katalog() -> list[dict[str, Any]]:
    """Die Werkzeuge, die das Gateway anbietet - abhaengig davon, was
    konfiguriert ist. Ohne Suchquelle gibt es die Suche nicht, statt sie
    anzubieten und dann zu scheitern."""
    werkzeuge: list[dict[str, Any]] = []

    if CONFIG.suche_verfuegbar:
        werkzeuge.append({
            "type": "function",
            "function": {
                "name": WEB_SUCHE,
                "description": (
                    "Sucht im Web und liefert Titel, Adresse und einen kurzen "
                    "Auszug der Treffer. Fuer aktuelle Angaben, die nicht im "
                    "Modell stehen koennen."
                ),
                "parameters": {
                    "type": "object",
                    "properties": {
                        "query": {
                            "type": "string",
                            "description": "Die Suchanfrage.",
                        }
                    },
                    "required": ["query"],
                },
            },
        })

    werkzeuge.append({
        "type": "function",
        "function": {
            "name": SEITE_ABRUFEN,
            "description": (
                "Ruft eine oeffentliche Webseite ab und liefert ihren Text. "
                "Nur http und https, nur oeffentliche Adressen."
            ),
            "parameters": {
                "type": "object",
                "properties": {
                    "url": {
                        "type": "string",
                        "description": "Vollstaendige Adresse der Seite.",
                    }
                },
                "required": ["url"],
            },
        },
    })
    return werkzeuge


class RechercheFehler(Exception):
    """Grund, der dem Nutzer angezeigt werden darf."""


# ---------------------------------------------------------------------------
# Adresspruefung
# ---------------------------------------------------------------------------

#: `ipaddress` kennt diese Bereiche nicht als privat, erreichbar sind sie
#: trotzdem - und im Zweifel liegt genau dort das Interessante.
_ZUSAETZLICH_GESPERRT = [
    # Tailscale und alles andere hinter CGNAT. Hier steht dieses Gateway
    # selbst, und hier stehen die anderen Rechner des Tailnets.
    ipaddress.ip_network("100.64.0.0/10"),
    # Cloud-Metadatendienste.
    ipaddress.ip_network("169.254.169.254/32"),
]


def _adresse_erlaubt(ip: ipaddress.IPv4Address | ipaddress.IPv6Address) -> bool:
    if (
        ip.is_private
        or ip.is_loopback
        or ip.is_link_local
        or ip.is_multicast
        or ip.is_reserved
        or ip.is_unspecified
    ):
        return False
    return not any(ip in netz for netz in _ZUSAETZLICH_GESPERRT)


async def pruefe_url(url: str) -> str:
    """Prueft eine Adresse und gibt sie zurueck, oder wirft mit Begruendung.

    Geprueft wird die **aufgeloeste** Adresse, nicht der Name: sonst genuegte
    ein Hostname, der auf 127.0.0.1 oder eine Tailscale-Adresse zeigt, um an
    der Pruefung vorbeizukommen. Alle Antworten des Namensdienstes muessen
    erlaubt sein, nicht nur die erste.
    """
    zerlegt = urlparse(url)
    if zerlegt.scheme not in ("http", "https"):
        raise RechercheFehler(
            f"Nur http und https sind erlaubt, nicht '{zerlegt.scheme or url[:20]}'."
        )
    if not zerlegt.hostname:
        raise RechercheFehler("Die Adresse enthaelt keinen Hostnamen.")

    port = zerlegt.port or (443 if zerlegt.scheme == "https" else 80)
    try:
        infos = await asyncio.get_running_loop().getaddrinfo(
            zerlegt.hostname, port, proto=socket.IPPROTO_TCP
        )
    except socket.gaierror as exc:
        raise RechercheFehler(
            f"Hostname '{zerlegt.hostname}' nicht aufloesbar: {exc}"
        ) from exc

    for eintrag in infos:
        roh = eintrag[4][0]
        try:
            ip = ipaddress.ip_address(roh)
        except ValueError:
            raise RechercheFehler(f"Unlesbare Adresse: {roh}")
        if not _adresse_erlaubt(ip):
            raise RechercheFehler(
                f"'{zerlegt.hostname}' zeigt auf {ip}, eine Adresse im lokalen "
                "Netz oder im Tailnet. Der Abruf ist auf oeffentliche Adressen "
                "beschraenkt."
            )
    return url


# ---------------------------------------------------------------------------
# Text aus HTML
# ---------------------------------------------------------------------------


class _TextSammler(HTMLParser):
    """Holt den sichtbaren Text heraus. Reicht fuer den Zweck und spart eine
    Abhaengigkeit; Skripte und Stile bleiben draussen."""

    _UEBERSPRINGEN = {"script", "style", "noscript", "svg", "head"}
    _ABSATZ = {"p", "div", "br", "li", "tr", "h1", "h2", "h3", "h4", "h5", "h6"}

    def __init__(self) -> None:
        super().__init__(convert_charrefs=True)
        self.teile: list[str] = []
        self._tiefe = 0

    def handle_starttag(self, tag: str, attrs: Any) -> None:
        if tag in self._UEBERSPRINGEN:
            self._tiefe += 1
        elif tag in self._ABSATZ:
            self.teile.append("\n")

    def handle_endtag(self, tag: str) -> None:
        if tag in self._UEBERSPRINGEN and self._tiefe:
            self._tiefe -= 1

    def handle_data(self, data: str) -> None:
        if not self._tiefe and data.strip():
            self.teile.append(data.strip())

    def text(self) -> str:
        roh = " ".join(self.teile)
        roh = re.sub(r"[ \t]+", " ", roh)
        return re.sub(r"\n\s*\n+", "\n\n", roh).strip()


def html_zu_text(roh: str) -> str:
    sammler = _TextSammler()
    try:
        sammler.feed(roh)
    except Exception:  # noqa: BLE001 - kaputtes HTML soll nichts umwerfen
        pass
    return sammler.text() or html.unescape(re.sub(r"<[^>]+>", " ", roh)).strip()


# ---------------------------------------------------------------------------
# Ausfuehrung
# ---------------------------------------------------------------------------


class Treffer(BaseModel):
    titel: str
    url: str
    auszug: str


class Ergebnis(BaseModel):
    """Was zurueck ins Gespraech geht - und was die App anzeigt."""

    werkzeug: str
    #: Der Text, der als Werkzeugergebnis ins naechste Prompt wandert.
    inhalt: str
    #: Quellen, damit im Chat sichtbar ist, worauf sich die Antwort stuetzt.
    quellen: list[Treffer] = []
    gekuerzt: bool = False


async def _abrufen(http: httpx.AsyncClient, url: str) -> tuple[str, str]:
    """Holt eine Seite, mit eigener Umleitungsverfolgung.

    httpx wuerde Umleitungen selbst folgen - dann bliebe das Ziel ungeprueft,
    und eine oeffentliche Adresse koennte auf 127.0.0.1 weiterleiten.
    """
    aktuell = url
    for _ in range(4):
        await pruefe_url(aktuell)
        antwort = await http.get(
            aktuell,
            follow_redirects=False,
            timeout=CONFIG.research_timeout,
            headers={"User-Agent": "local-ai-remote/1.0 (Recherche-Werkzeug)"},
        )
        if antwort.is_redirect:
            ziel = antwort.headers.get("location")
            if not ziel:
                raise RechercheFehler("Umleitung ohne Ziel.")
            aktuell = str(httpx.URL(aktuell).join(ziel))
            continue

        if antwort.status_code >= 400:
            raise RechercheFehler(
                f"Die Seite antwortete mit {antwort.status_code}."
            )
        typ = antwort.headers.get("content-type", "")
        if not any(t in typ for t in ("text/", "json", "xml")):
            raise RechercheFehler(
                f"Inhaltstyp '{typ or 'unbekannt'}' wird nicht gelesen; nur Text."
            )
        return antwort.text, aktuell

    raise RechercheFehler("Zu viele Umleitungen.")


async def _suchen(http: httpx.AsyncClient, anfrage: str) -> list[Treffer]:
    quelle = CONFIG.search_provider
    if quelle == "searxng":
        antwort = await http.get(
            f"{CONFIG.searxng_url.rstrip('/')}/search",
            params={"q": anfrage, "format": "json"},
            timeout=CONFIG.research_timeout,
        )
        antwort.raise_for_status()
        roh = antwort.json().get("results", [])
        return [
            Treffer(
                titel=str(t.get("title") or "")[:200],
                url=str(t.get("url") or ""),
                auszug=str(t.get("content") or "")[:400],
            )
            for t in roh[: CONFIG.research_max_results]
            if t.get("url")
        ]

    if quelle == "brave":
        antwort = await http.get(
            "https://api.search.brave.com/res/v1/web/search",
            params={"q": anfrage, "count": CONFIG.research_max_results},
            headers={
                "X-Subscription-Token": CONFIG.brave_key,
                "Accept": "application/json",
            },
            timeout=CONFIG.research_timeout,
        )
        antwort.raise_for_status()
        roh = (antwort.json().get("web") or {}).get("results", [])
        return [
            Treffer(
                titel=str(t.get("title") or "")[:200],
                url=str(t.get("url") or ""),
                auszug=html_zu_text(str(t.get("description") or ""))[:400],
            )
            for t in roh
            if t.get("url")
        ]

    raise RechercheFehler(
        "Keine Suchquelle eingerichtet. GATEWAY_SEARCH_PROVIDER auf 'searxng' "
        "oder 'brave' setzen (siehe AGENTS.md)."
    )


async def ausfuehren(
    http: httpx.AsyncClient, name: str, argumente: str
) -> Ergebnis:
    """Fuehrt einen freigegebenen Werkzeugaufruf aus.

    ``argumente`` ist der JSON-String des Modells und damit unzuverlaessig -
    er wird geprueft, nicht geglaubt.
    """
    try:
        werte = json.loads(argumente or "{}")
    except json.JSONDecodeError as exc:
        raise RechercheFehler(
            f"Die Argumente des Modells sind kein gueltiges JSON: {exc}"
        ) from exc
    if not isinstance(werte, dict):
        raise RechercheFehler("Die Argumente des Modells sind kein Objekt.")

    if name == WEB_SUCHE:
        anfrage = str(werte.get("query") or "").strip()
        if not anfrage:
            raise RechercheFehler("Leere Suchanfrage.")
        treffer = await _suchen(http, anfrage)
        if not treffer:
            return Ergebnis(werkzeug=name, inhalt="Keine Treffer.", quellen=[])
        zeilen = [
            f"{i}. {t.titel}\n   {t.url}\n   {t.auszug}"
            for i, t in enumerate(treffer, 1)
        ]
        return Ergebnis(
            werkzeug=name, inhalt="\n\n".join(zeilen), quellen=treffer
        )

    if name == SEITE_ABRUFEN:
        url = str(werte.get("url") or "").strip()
        if not url:
            raise RechercheFehler("Keine Adresse angegeben.")
        roh, endgueltig = await _abrufen(http, url)
        text = html_zu_text(roh)
        grenze = CONFIG.research_max_chars
        gekuerzt = len(text) > grenze
        if gekuerzt:
            text = text[:grenze]
        return Ergebnis(
            werkzeug=name,
            inhalt=text or "Die Seite enthielt keinen lesbaren Text.",
            quellen=[Treffer(titel=endgueltig, url=endgueltig, auszug="")],
            gekuerzt=gekuerzt,
        )

    raise RechercheFehler(
        f"'{name}' ist kein Recherche-Werkzeug dieses Gateways."
    )


def ist_recherchewerkzeug(name: Optional[str]) -> bool:
    return name in (WEB_SUCHE, SEITE_ABRUFEN)
