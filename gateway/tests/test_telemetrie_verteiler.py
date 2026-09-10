"""Der Telemetrieverteiler.

CPU- und GPU-Auslastung sind **Differenzmessungen**: sie brauchen zwei
Messpunkte mit Abstand dazwischen. Solange jede WebSocket-Verbindung den
Leser selbst antrieb, ging das mit einem Zuhoerer gut und mit zweien kaputt -
zwei Abrufe dicht beieinander ergeben ein Zeitfenster nahe null, und die
Anzeige sprang zwischen dem echten Wert und 0 %.

Genau das pruefen diese Tests: **einmal messen, an alle verteilen.**
"""

from __future__ import annotations

import asyncio

import pytest

from gateway.schema import Fact, TelemetrySample
from gateway.telemetry import Telemetrieverteiler


class ZaehlenderLeser:
    """Zaehlt, wie oft gemessen wurde, und nummeriert die Proben."""

    def __init__(self) -> None:
        self.messungen = 0

    def sample(self) -> TelemetrySample:
        self.messungen += 1
        from datetime import datetime, timezone

        return TelemetrySample(
            at=datetime.now(timezone.utc),
            cpu_percent=Fact.of(float(self.messungen)),
        )


@pytest.mark.asyncio
async def test_zwei_zuhoerer_treiben_den_leser_nicht_doppelt():
    leser = ZaehlenderLeser()
    verteiler = Telemetrieverteiler(leser, interval=0.05)

    async with verteiler.zuhoeren() as a, verteiler.zuhoeren() as b:
        erste_a = await asyncio.wait_for(a.get(), 2)
        erste_b = await asyncio.wait_for(b.get(), 2)

    # Beide bekommen dieselbe Messung, nicht je eine eigene.
    assert erste_a.cpu_percent.value == erste_b.cpu_percent.value
    assert leser.messungen <= 2, (
        "eine Messung je Takt, unabhaengig von der Zahl der Zuhoerer"
    )


@pytest.mark.asyncio
async def test_ohne_zuhoerer_wird_nicht_gemessen():
    leser = ZaehlenderLeser()
    verteiler = Telemetrieverteiler(leser, interval=0.02)

    await asyncio.sleep(0.1)
    assert leser.messungen == 0, "ohne Zuhoerer gibt es nichts zu messen"

    async with verteiler.zuhoeren() as q:
        await asyncio.wait_for(q.get(), 2)
    vorher = leser.messungen

    # Nach dem letzten Zuhoerer haelt der Takt wieder an - sonst blieben die
    # PDH-Abfragen offen und die Messung liefe ins Leere.
    await asyncio.sleep(0.1)
    assert leser.messungen == vorher


@pytest.mark.asyncio
async def test_langsamer_zuhoerer_bremst_die_anderen_nicht():
    leser = ZaehlenderLeser()
    verteiler = Telemetrieverteiler(leser, interval=0.02)

    async with verteiler.zuhoeren() as schnell, verteiler.zuhoeren() as langsam:
        # `langsam` liest nie; seine Warteschlange fasst genau einen Wert.
        werte = [
            (await asyncio.wait_for(schnell.get(), 2)).cpu_percent.value
            for _ in range(4)
        ]

        assert werte == sorted(werte), "der schnelle Zuhoerer bekommt der Reihe nach"
        assert langsam.qsize() <= 1

        # Und er bekommt die *neueste* Messung, nicht die aelteste.
        stehengeblieben = (await asyncio.wait_for(langsam.get(), 2)).cpu_percent.value
        assert stehengeblieben >= werte[-1] - 1


@pytest.mark.asyncio
async def test_ein_neuer_zuhoerer_startet_den_takt_erneut():
    leser = ZaehlenderLeser()
    verteiler = Telemetrieverteiler(leser, interval=0.02)

    async with verteiler.zuhoeren() as q:
        await asyncio.wait_for(q.get(), 2)

    async with verteiler.zuhoeren() as q:
        probe = await asyncio.wait_for(q.get(), 2)

    assert probe is not None
