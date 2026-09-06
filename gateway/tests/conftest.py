"""Gemeinsame Vorbedingungen fuer alle Gateway-Tests.

Die Konfiguration wird beim Import aus der Umgebung und aus ``gateway/.env``
gelesen. Ohne Gegenmassnahme entscheidet damit die lokale Einrichtung
darueber, was ein Test vorfindet: wer Recherche eingeschaltet oder ein
Agenten-Token gesetzt hat, sieht andere Ergebnisse als die CI.

Genau das ist hier dreimal passiert - erst beim Agenten-Token, dann bei der
Recherche, dann bei der Suchquelle. Deshalb setzt diese Datei fuer *jeden*
Test einen bekannten Ausgangszustand. Was ein Test darueber hinaus braucht,
setzt er selbst.
"""

from __future__ import annotations

import dataclasses

import pytest

from gateway import main as gw
from gateway import openai_api, research, responses_api
from gateway.config import Config

#: Neutraler Ausgangszustand: alles aus, nichts eingerichtet.
NEUTRAL = dict(
    token="test-token-mit-genug-laenge",
    agent_token="",
    research_enabled=False,
    search_provider="none",
    searxng_url="",
    brave_key="",
)

#: Jedes Modul haelt beim Import eine eigene Referenz auf CONFIG.
_MODULE = (gw, openai_api, research, responses_api)


@pytest.fixture(autouse=True)
def neutrale_konfiguration(monkeypatch) -> Config:
    """Setzt vor jedem Test eine Konfiguration ohne lokale Eigenheiten."""
    cfg = dataclasses.replace(gw.CONFIG, **NEUTRAL)
    for modul in _MODULE:
        if hasattr(modul, "CONFIG"):
            monkeypatch.setattr(modul, "CONFIG", cfg)
    return cfg
