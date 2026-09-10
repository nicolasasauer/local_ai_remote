"""Auswertung der Windows-Leistungsindikatoren.

Der ctypes-Teil laesst sich nur unter Windows ausfuehren; die Auswertung der
Zaehlernamen ist reine Rechnung und wird hier ueberall geprueft. Genau dort
sitzt auch das Fehlerpotenzial: Windows misst je Engine **und** je Prozess,
und die Instanznamen haben zwei verschiedene Formen.
"""

from __future__ import annotations

import sys

import pytest

from gateway.windows_gpu import (
    _luid_aus_instanz,
    auslastung_aus_zaehlern,
    speicher_aus_zaehlern,
)

RX = "0x00000000_0x0000e495"
IGPU = "0x00000000_0x00011938"


def engine(pid: int, luid: str, art: str) -> str:
    """Wie Windows eine Engine-Instanz benennt."""
    return f"pid_{pid}_luid_{luid.upper()}_phys_0_eng_0_engtype_{art}"


class TestInstanznamen:
    def test_engine_instanz(self):
        assert _luid_aus_instanz(engine(5624, RX, "3D")) == RX

    def test_speicher_instanz(self):
        # Andere Form: kein pid-Praefix, kein engtype.
        assert _luid_aus_instanz(f"luid_{RX.upper()}_phys_0") == RX

    def test_schreibweise_wird_vereinheitlicht(self):
        # PDH schreibt Hex gross, DXGI liefert Zahlen. Ohne Angleichung
        # faenden sich die beiden Quellen nie.
        assert _luid_aus_instanz(f"luid_{RX.upper()}_phys_0") == RX.lower()

    def test_fremde_namen_ergeben_nichts(self):
        assert _luid_aus_instanz("irgendwas") is None
        assert _luid_aus_instanz("luid_ohne_phys") is None


class TestAuslastung:
    def test_prozesse_einer_engine_werden_addiert(self):
        # Drei Prozesse rechnen gleichzeitig auf derselben Engine.
        werte = auslastung_aus_zaehlern([
            (engine(1, RX, "Compute 0"), 40.0),
            (engine(2, RX, "Compute 0"), 30.0),
            (engine(3, RX, "Compute 0"), 20.0),
        ])
        assert werte[RX] == pytest.approx(90.0)

    def test_ueber_engine_arten_zaehlt_das_maximum(self):
        # Eine Summe ueber alle Arten laege hier bei 150 % und waere keine
        # Auslastung mehr - der Task-Manager zeigt ebenfalls das Maximum.
        werte = auslastung_aus_zaehlern([
            (engine(1, RX, "Compute 0"), 90.0),
            (engine(1, RX, "3D"), 40.0),
            (engine(1, RX, "Copy"), 20.0),
        ])
        assert werte[RX] == pytest.approx(90.0)

    def test_adapter_bleiben_getrennt(self):
        werte = auslastung_aus_zaehlern([
            (engine(1, RX, "Compute 0"), 95.0),
            (engine(2, IGPU, "3D"), 12.0),
        ])
        assert werte[RX] == pytest.approx(95.0)
        assert werte[IGPU] == pytest.approx(12.0)

    def test_ueber_hundert_wird_gedeckelt(self):
        # Messungenauigkeit bei vielen Prozessen; 130 % waere unbrauchbar.
        werte = auslastung_aus_zaehlern([
            (engine(i, RX, "Compute 0"), 65.0) for i in range(2)
        ])
        assert werte[RX] == 100.0

    def test_instanzen_ohne_engine_typ_werden_ignoriert(self):
        assert auslastung_aus_zaehlern([(f"luid_{RX.upper()}_phys_0", 50.0)]) == {}


class TestSpeicher:
    def test_werte_je_adapter(self):
        werte = speicher_aus_zaehlern([
            (f"luid_{RX.upper()}_phys_0", 16_000_000_000.0),
            (f"luid_{IGPU.upper()}_phys_0", 2_000_000.0),
        ])
        assert werte[RX] == 16_000_000_000
        assert werte[IGPU] == 2_000_000

    def test_mehrere_physische_bereiche_werden_addiert(self):
        werte = speicher_aus_zaehlern([
            (f"luid_{RX.upper()}_phys_0", 1_000.0),
            (f"luid_{RX.upper()}_phys_1", 2_000.0),
        ])
        assert werte[RX] == 3_000


class TestBezugspunkt:
    """Auslastung ist eine Rate und braucht zwei Messpunkte.

    Der erste wird beim Anlegen gesetzt. Das ging schon einmal schief:
    `_sammeln` ist ein Generator, und ein nicht ausgelesener Generator fuehrt
    gar nichts aus - der Bezugspunkt fehlte, und die erste Auslastung nach
    jedem Gateway-Start war 0 %.
    """

    def test_sammeln_ist_ein_generator(self):
        import inspect

        from gateway.windows_gpu import WindowsGpuZaehler

        # Wenn das je aufhoert zu gelten, ist die Falle weg - und dieser Test
        # darf verschwinden.
        assert inspect.isgeneratorfunction(WindowsGpuZaehler._sammeln)

    def test_bezugspunkt_sammelt_wirklich(self):
        from gateway.windows_gpu import WindowsGpuZaehler

        class FakePdh:
            def __init__(self):
                self.aufrufe = 0

            def PdhCollectQueryData(self, abfrage):
                self.aufrufe += 1
                return 0

        # Ohne __init__, damit der Test ohne Windows laeuft.
        z = object.__new__(WindowsGpuZaehler)
        z._pdh = FakePdh()
        z._engine = ("abfrage-engine", "zaehler")
        z._speicher = ("abfrage-speicher", "zaehler")

        z._bezugspunkt()

        assert z._pdh.aufrufe == 2, "beide Abfragen brauchen einen Bezugspunkt"


@pytest.mark.skipif(sys.platform != "win32", reason="nur unter Windows")
class TestGegenDasEchteSystem:
    """Prueft die ctypes-Anbindung, nicht die Werte selbst."""

    def test_dxgi_nennt_mindestens_eine_karte(self):
        from gateway.windows_gpu import adapter_lesen

        adapter = adapter_lesen()
        assert adapter, "DXGI sollte auf einem Windows-Desktop etwas finden"
        for luid, karte in adapter.items():
            assert karte.name
            assert luid.startswith("0x")
            # Software-Adapter ("Microsoft Basic Render Driver") sind keine
            # Karten und gehoeren nicht in die Liste.
            assert "Basic Render" not in karte.name

    def test_unbekannte_adapter_werden_uebergangen(self):
        # Windows zaehlt auch den "Microsoft Basic Render Driver" mit. Dessen
        # LUID taucht in den Zaehlern auf, aber nicht in der Kartenliste -
        # gemeldet werden darf nur, was DXGI als echte Karte kennt.
        import time

        from gateway.telemetry import _WindowsZaehlerProbe
        from gateway.windows_gpu import WindowsGpuZaehler, adapter_lesen

        bekannt = set(adapter_lesen())
        zaehler = WindowsGpuZaehler()
        aus_zaehlern = set(zaehler.belegter_speicher())
        assert aus_zaehlern, "ohne Messwerte sagt der Test nichts aus"

        probe = _WindowsZaehlerProbe()
        probe()
        time.sleep(1.1)
        gemeldet = probe()

        assert gemeldet
        for eintrag in gemeldet:
            assert eintrag.name
            assert "Basic Render" not in eintrag.name
            assert eintrag.source == "windows-counters"
        # Und die Temperatur wird nicht erfunden, sondern begruendet.
        assert gemeldet[0].temp_c.value is None
        assert gemeldet[0].temp_c.note
