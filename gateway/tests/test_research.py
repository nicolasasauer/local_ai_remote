"""Recherche: die Absicherung des Abrufs.

Dies ist die einzige Stelle, an der das Gateway etwas ausfuehrt, und der
Abruf ist der gefaehrliche Teil. Die Adresse kann aus dem Modell stammen oder
aus einer Seite, die es vorher gelesen hat - beides ist nicht
vertrauenswuerdig. Ohne Pruefung waere das Gateway ein Werkzeug, mit dem sich
aus dem Internet heraus das lokale Netz und das Tailnet abklopfen laesst.
"""

from __future__ import annotations

import dataclasses
import socket

import httpx
import pytest
from fastapi.testclient import TestClient

from gateway import main as gw
from gateway import openai_api, research
from gateway.research import (
    RechercheFehler,
    ausfuehren,
    html_zu_text,
    ist_recherchewerkzeug,
    pruefe_url,
)

from gateway.schema import BackendId

from .test_gateway import TOKEN, auth, backends, client  # noqa: F401


def _aufloesung(monkeypatch, adressen: list[str]):
    """Namensaufloesung faelschen, damit die Pruefung ohne Netz testbar ist."""

    async def getaddrinfo(host, port, **kw):
        return [
            (socket.AF_INET, socket.SOCK_STREAM, socket.IPPROTO_TCP, "", (a, port))
            for a in adressen
        ]

    import asyncio
    from types import SimpleNamespace

    monkeypatch.setattr(
        asyncio, "get_running_loop",
        lambda: SimpleNamespace(getaddrinfo=getaddrinfo),
    )


class TestAdresspruefung:
    @pytest.mark.asyncio
    async def test_oeffentliche_adresse_geht_durch(self, monkeypatch):
        _aufloesung(monkeypatch, ["93.184.216.34"])
        assert await pruefe_url("https://example.com/seite") == (
            "https://example.com/seite"
        )

    @pytest.mark.parametrize(
        "adresse,was",
        [
            ("127.0.0.1", "Loopback"),
            ("192.168.1.10", "Heimnetz"),
            ("10.0.0.5", "privates Netz"),
            ("172.16.0.1", "privates Netz"),
            ("169.254.169.254", "Cloud-Metadaten"),
            # Der wichtigste Fall: `ipaddress` haelt Tailscale-Adressen nicht
            # fuer privat. Hier steht dieses Gateway selbst.
            ("100.101.102.103", "Tailnet"),
            ("100.64.0.1", "Tailnet"),
        ],
    )
    @pytest.mark.asyncio
    async def test_interne_adressen_werden_abgelehnt(self, monkeypatch, adresse, was):
        _aufloesung(monkeypatch, [adresse])
        with pytest.raises(RechercheFehler, match="lokalen Netz oder im Tailnet"):
            await pruefe_url("https://harmlos.example/")

    @pytest.mark.asyncio
    async def test_eine_schlechte_antwort_genuegt(self, monkeypatch):
        # DNS-Rebinding: ein Name loest auf mehrere Adressen auf, eine davon
        # ist intern. Nur die erste zu pruefen waere wertlos.
        _aufloesung(monkeypatch, ["93.184.216.34", "127.0.0.1"])
        with pytest.raises(RechercheFehler):
            await pruefe_url("https://doppelt.example/")

    @pytest.mark.asyncio
    async def test_fremde_schemata_werden_abgelehnt(self):
        for url in ("file:///etc/passwd", "ftp://host/x", "gopher://host"):
            with pytest.raises(RechercheFehler, match="http"):
                await pruefe_url(url)

    @pytest.mark.asyncio
    async def test_ohne_hostnamen_abgelehnt(self):
        with pytest.raises(RechercheFehler, match="Hostnamen"):
            await pruefe_url("http:///nur-pfad")


class TestTextgewinnung:
    def test_skripte_und_stile_bleiben_draussen(self):
        roh = (
            "<html><head><style>p{color:red}</style></head>"
            "<body><script>alert(1)</script><p>Sichtbarer Text</p></body></html>"
        )
        text = html_zu_text(roh)
        assert "Sichtbarer Text" in text
        assert "alert" not in text
        assert "color:red" not in text

    def test_entities_werden_aufgeloest(self):
        assert "A & B" in html_zu_text("<p>A &amp; B</p>")

    def test_kaputtes_html_wirft_nicht(self):
        assert html_zu_text("<p>offen <b>fett") .strip()


class TestAusfuehrung:
    @pytest.mark.asyncio
    async def test_unbekanntes_werkzeug_wird_abgelehnt(self):
        async with httpx.AsyncClient() as http:
            with pytest.raises(RechercheFehler, match="kein Recherche-Werkzeug"):
                await ausfuehren(http, "rm_minus_rf", "{}")

    @pytest.mark.asyncio
    async def test_kaputte_argumente_werden_gemeldet(self):
        # Die Argumente kommen vom Modell - geprueft, nicht geglaubt.
        async with httpx.AsyncClient() as http:
            with pytest.raises(RechercheFehler, match="kein gueltiges JSON"):
                await ausfuehren(http, research.SEITE_ABRUFEN, "{kaputt")

    @pytest.mark.asyncio
    async def test_umleitung_ins_lokale_netz_wird_gestoppt(self, monkeypatch):
        # Eine oeffentliche Seite leitet auf 127.0.0.1 weiter. httpx wuerde
        # dem folgen, ohne erneut zu pruefen - deshalb folgt der Adapter
        # selbst und prueft jedes Ziel.
        adressen = {"oeffentlich.example": "93.184.216.34", "intern.example": "127.0.0.1"}

        async def getaddrinfo(host, port, **kw):
            return [(socket.AF_INET, socket.SOCK_STREAM, socket.IPPROTO_TCP, "",
                     (adressen[host], port))]

        import asyncio
        from types import SimpleNamespace

        monkeypatch.setattr(
            asyncio, "get_running_loop",
            lambda: SimpleNamespace(getaddrinfo=getaddrinfo),
        )

        def handler(request: httpx.Request) -> httpx.Response:
            return httpx.Response(302, headers={"location": "http://intern.example/geheim"})

        async with httpx.AsyncClient(transport=httpx.MockTransport(handler)) as http:
            with pytest.raises(RechercheFehler, match="lokalen Netz oder im Tailnet"):
                await ausfuehren(
                    http, research.SEITE_ABRUFEN,
                    '{"url": "http://oeffentlich.example/start"}',
                )

    @pytest.mark.asyncio
    async def test_seite_wird_gekuerzt_und_das_vermerkt(self, monkeypatch):
        _aufloesung(monkeypatch, ["93.184.216.34"])
        lang = "<p>" + ("wort " * 20000) + "</p>"

        def handler(request: httpx.Request) -> httpx.Response:
            return httpx.Response(200, text=lang,
                                  headers={"content-type": "text/html"})

        async with httpx.AsyncClient(transport=httpx.MockTransport(handler)) as http:
            ergebnis = await ausfuehren(
                http, research.SEITE_ABRUFEN, '{"url": "https://example.com/"}'
            )

        assert ergebnis.gekuerzt is True
        assert len(ergebnis.inhalt) <= gw.CONFIG.research_max_chars
        assert ergebnis.quellen[0].url == "https://example.com/"

    @pytest.mark.asyncio
    async def test_binaerinhalt_wird_nicht_gelesen(self, monkeypatch):
        _aufloesung(monkeypatch, ["93.184.216.34"])

        def handler(request: httpx.Request) -> httpx.Response:
            return httpx.Response(200, content=b"\x00\x01",
                                  headers={"content-type": "application/pdf"})

        async with httpx.AsyncClient(transport=httpx.MockTransport(handler)) as http:
            with pytest.raises(RechercheFehler, match="nicht gelesen"):
                await ausfuehren(
                    http, research.SEITE_ABRUFEN, '{"url": "https://example.com/x.pdf"}'
                )

    @pytest.mark.asyncio
    async def test_ohne_suchquelle_kommt_eine_begruendung(self, monkeypatch):
        monkeypatch.setattr(
            research, "CONFIG", dataclasses.replace(gw.CONFIG, search_provider="none")
        )
        async with httpx.AsyncClient() as http:
            with pytest.raises(RechercheFehler, match="Keine Suchquelle"):
                await ausfuehren(http, research.WEB_SUCHE, '{"query": "irgendwas"}')


class TestKatalog:
    """Der Katalog haengt an der Konfiguration - die wird hier gesetzt, nicht
    aus der Umgebung uebernommen. Sonst entscheidet eine lokale .env darueber,
    was der Test vorfindet."""

    def _mit(self, monkeypatch, **felder):
        monkeypatch.setattr(
            research, "CONFIG", dataclasses.replace(gw.CONFIG, **felder)
        )

    def test_ohne_suchquelle_wird_suche_nicht_angeboten(self, monkeypatch):
        self._mit(monkeypatch, search_provider="none", searxng_url="", brave_key="")
        namen = [w["function"]["name"] for w in research.katalog()]
        # Ein Werkzeug anzubieten, das dann an der Konfiguration scheitert,
        # kostet einen Zug und eine Freigabe fuer nichts.
        assert research.WEB_SUCHE not in namen
        assert research.SEITE_ABRUFEN in namen

    def test_mit_suchquelle_ist_die_suche_dabei(self, monkeypatch):
        self._mit(
            monkeypatch, search_provider="searxng", searxng_url="http://such.example"
        )
        namen = [w["function"]["name"] for w in research.katalog()]
        assert research.WEB_SUCHE in namen

    def test_eingetragene_quelle_ohne_adresse_zaehlt_nicht(self, monkeypatch):
        # Ein Werkzeug anzubieten, das an fehlender Adresse scheitert, kostet
        # einen Zug und eine Freigabe fuer nichts.
        self._mit(monkeypatch, search_provider="searxng", searxng_url="")
        assert research.WEB_SUCHE not in [
            w["function"]["name"] for w in research.katalog()
        ]

    def test_erkennung_der_eigenen_werkzeuge(self):
        assert ist_recherchewerkzeug(research.WEB_SUCHE)
        assert ist_recherchewerkzeug(research.SEITE_ABRUFEN)
        assert not ist_recherchewerkzeug("shell")
        assert not ist_recherchewerkzeug(None)


@pytest.fixture
def research_client(backends, monkeypatch):  # noqa: F811
    cfg = dataclasses.replace(gw.CONFIG, token=TOKEN, agent_token="",
                              research_enabled=True)
    monkeypatch.setattr(gw, "CONFIG", cfg)
    monkeypatch.setattr(openai_api, "CONFIG", cfg)
    monkeypatch.setattr(research, "CONFIG", cfg)
    with TestClient(gw.app) as c:
        monkeypatch.setattr(gw, "_backends", backends)
        yield c


class TestEndpunkt:
    def _chat(self, client, **extra):
        koerper = {
            "backend": "ollama", "model": "m1",
            "messages": [{"role": "user", "content": "hi"}],
        }
        koerper.update(extra)
        return client.post("/v1/chat", headers=auth(), json=koerper)

    def test_recherche_haengt_den_katalog_an(self, research_client, backends):  # noqa: F811
        self._chat(research_client, research=True)
        gesendet = backends[BackendId.ollama].seen[-1]
        namen = [w["function"]["name"] for w in gesendet.tools]
        assert research.SEITE_ABRUFEN in namen

    def test_ohne_recherche_keine_werkzeuge(self, research_client, backends):  # noqa: F811
        self._chat(research_client)
        assert backends[BackendId.ollama].seen[-1].tools == []

    def test_app_kann_keine_eigenen_werkzeuge_vorgeben(self, research_client, backends):  # noqa: F811
        # Der Katalog gehoert dem Gateway. Sonst koennte die App das Gateway
        # bitten, etwas auszufuehren, das es nie definiert hat.
        self._chat(
            research_client, research=True,
            tools=[{"type": "function", "function": {"name": "rm_minus_rf"}}],
        )
        namen = [w["function"]["name"] for w in backends[BackendId.ollama].seen[-1].tools]
        assert "rm_minus_rf" not in namen

    def test_fremdes_werkzeug_wird_nicht_ausgefuehrt(self, research_client):
        r = research_client.post("/v1/research", headers=auth(),
                                 json={"name": "shell", "arguments": "{}"})
        assert r.status_code == 400
        assert "kein Recherche-Werkzeug" in r.json()["detail"]

    def test_ohne_token_401(self, research_client):
        r = research_client.post("/v1/research",
                                 json={"name": research.SEITE_ABRUFEN})
        assert r.status_code == 401

    def test_abgeschaltet_gibt_409(self, client):  # noqa: F811
        # `client` laesst research_enabled aus.
        r = client.post("/v1/research", headers=auth(),
                        json={"name": research.SEITE_ABRUFEN})
        assert r.status_code == 409
        assert "nicht eingeschaltet" in r.json()["detail"]

    def test_chat_mit_recherche_ohne_schalter_gibt_409(self, client):  # noqa: F811
        r = self._chat(client, research=True)
        assert r.status_code == 409
