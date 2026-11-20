"""Modell-Downloads ueber Ollama, als Hintergrundauftrag.

Neben der Recherche die zweite Stelle, an der das Gateway auf Zuruf etwas
*tut*: es laesst Ollama Gigabytes aus dem Netz auf die Platte des Desktops
laden. Deshalb standardmaessig aus (``GATEWAY_ALLOW_PULL=1``), nur mit dem
App-Token erreichbar und immer nur ein Download zur Zeit.

Der Download haengt nicht an der Verbindung der App. Ein Telefon, das in die
Tasche wandert, soll 20 GB nicht abbrechen - die App fragt den Stand ab,
wann immer sie wieder da ist.
"""

from __future__ import annotations

import asyncio
import logging
from datetime import datetime, timedelta, timezone
from typing import Any, AsyncIterator, Callable

from .backends.base import BackendError, check_model_name
from .schema import PullJob, PullState

log = logging.getLogger("gateway.pulls")

#: Abgeschlossene Auftraege bleiben so lange sichtbar - lange genug, dass die
#: App das Ergebnis sieht, auch wenn sie zwischendurch weg war.
_AUFBEWAHREN = timedelta(hours=6)

PullFn = Callable[[str], AsyncIterator[dict[str, Any]]]


class PullBusy(Exception):
    pass


def _now() -> datetime:
    return datetime.now(timezone.utc)


class PullManager:
    def __init__(self) -> None:
        self._jobs: dict[str, PullJob] = {}
        self._tasks: dict[str, asyncio.Task[None]] = {}

    def jobs(self) -> list[PullJob]:
        self._aufraeumen()
        return sorted(self._jobs.values(), key=lambda j: j.started_at, reverse=True)

    def running(self) -> PullJob | None:
        return next(
            (j for j in self._jobs.values() if j.state is PullState.running), None
        )

    def start(self, model: str, pull: PullFn) -> PullJob:
        check_model_name(model)
        laufend = self.running()
        if laufend is not None:
            # Zwei parallele Downloads teilen sich nur die Leitung und
            # verdoppeln den Plattenbedarf, bevor einer fertig ist.
            raise PullBusy(f"Es laeuft bereits ein Download: {laufend.model}")
        job = PullJob(model=model, state=PullState.running, started_at=_now())
        self._jobs[model] = job
        task = asyncio.create_task(self._run(job, pull))
        # Ein Abbruch, bevor die Aufgabe ueberhaupt laeuft, erreicht `_run`
        # nie - ohne diesen Rueckruf stuende der Auftrag fuer immer auf
        # "laeuft" und blockierte jeden weiteren Download.
        task.add_done_callback(lambda t: self._abgeschlossen(job, t))
        self._tasks[model] = task
        log.info("Download gestartet: %s", model)
        return job

    def cancel(self, model: str) -> bool:
        task = self._tasks.get(model)
        if task is None or task.done():
            return False
        task.cancel()
        return True

    async def shutdown(self) -> None:
        for task in self._tasks.values():
            task.cancel()
        await asyncio.gather(*self._tasks.values(), return_exceptions=True)

    async def _run(self, job: PullJob, pull: PullFn) -> None:
        # Ollama meldet jede Schicht (digest) einzeln. Der Gesamtfortschritt
        # ist die Summe; eine Schicht ohne total zaehlt noch nicht mit.
        schichten: dict[str, tuple[int, int]] = {}
        try:
            async for zeile in pull(job.model):
                if "error" in zeile:
                    raise BackendError(str(zeile["error"]))
                job.status = str(zeile.get("status", job.status))
                digest = zeile.get("digest")
                total = zeile.get("total")
                if digest and isinstance(total, int) and total > 0:
                    done = zeile.get("completed")
                    schichten[digest] = (
                        done if isinstance(done, int) else 0,
                        total,
                    )
                    job.completed = sum(c for c, _ in schichten.values())
                    job.total = sum(t for _, t in schichten.values())
                if job.status == "success":
                    job.state = PullState.done
                    if job.total is not None:
                        job.completed = job.total
                    break
            else:
                # Strom zu Ende ohne "success": das ist kein Erfolg.
                raise BackendError("Ollama hat den Download ohne Abschluss beendet")
        except asyncio.CancelledError:
            job.state = PullState.cancelled
            job.status = "abgebrochen"
            log.info("Download abgebrochen: %s", job.model)
        except BackendError as exc:
            job.state = PullState.failed
            job.error = exc.message
            log.warning("Download fehlgeschlagen: %s: %s", job.model, exc.message)
        except Exception as exc:  # noqa: BLE001 - Grund soll in der App ankommen
            job.state = PullState.failed
            job.error = f"{type(exc).__name__}: {exc}"
            log.warning("Download fehlgeschlagen: %s: %s", job.model, job.error)
        finally:
            job.finished_at = _now()

    def _abgeschlossen(self, job: PullJob, task: "asyncio.Task[None]") -> None:
        if job.state is PullState.running:
            job.state = PullState.cancelled if task.cancelled() else PullState.failed
            job.status = "abgebrochen" if task.cancelled() else job.status
            job.finished_at = job.finished_at or _now()
        if self._tasks.get(job.model) is task:
            del self._tasks[job.model]

    def _aufraeumen(self) -> None:
        grenze = _now() - _AUFBEWAHREN
        for name, job in list(self._jobs.items()):
            if job.finished_at is not None and job.finished_at < grenze:
                del self._jobs[name]
