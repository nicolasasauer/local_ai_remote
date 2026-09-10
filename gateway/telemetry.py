"""CPU-, RAM- und GPU-Telemetrie.

CPU und RAM sind ueber psutil trivial. Bei AMD ist es das nicht: es gibt keine
verlaessliche Bibliothek, die auf Windows und Linux gleich funktioniert. Deshalb
werden mehrere Quellen der Reihe nach probiert, und wenn keine greift, wird der
konkrete Grund mitgeliefert statt einer Null. Eine nicht auslesbare GPU-Last
sieht sonst genauso aus wie eine im Idle.
"""

from __future__ import annotations

import json
import shutil
import subprocess
from datetime import datetime, timezone
from typing import Any, Callable

import psutil

from . import windows_gpu
from .schema import Certainty, Fact, GpuSample, TelemetrySample

_MIB = 1024 * 1024


def _run(cmd: list[str], timeout: float = 4.0) -> str:
    proc = subprocess.run(cmd, capture_output=True, text=True, timeout=timeout)
    if proc.returncode != 0:
        raise RuntimeError((proc.stderr or proc.stdout or "").strip()[:200])
    return proc.stdout


def _probe_rocm_smi() -> list[GpuSample]:
    """Linux mit ROCm-Stack."""
    exe = shutil.which("rocm-smi")
    if not exe:
        raise FileNotFoundError("rocm-smi nicht im PATH")

    raw = _run(
        [exe, "--showuse", "--showmemuse", "--showtemp", "--showpower", "--json"]
    )
    data = json.loads(raw)

    def pick(card: dict[str, Any], *needles: str) -> Any:
        for key, value in card.items():
            lowered = key.lower()
            if all(n in lowered for n in needles):
                return value
        return None

    def as_float(value: Any) -> float | None:
        try:
            return float(str(value).strip().rstrip("%").split()[0])
        except (TypeError, ValueError, IndexError):
            return None

    samples: list[GpuSample] = []
    for name, card in data.items():
        if not name.lower().startswith("card"):
            continue
        used = as_float(pick(card, "vram", "used"))
        total = as_float(pick(card, "vram", "total"))
        samples.append(
            GpuSample(
                name=str(pick(card, "card", "series") or pick(card, "card", "model") or name),
                vendor="amd",
                source="rocm-smi",
                util_percent=Fact.maybe(
                    as_float(pick(card, "gpu", "use")),
                    "GPU-Auslastung nicht in der rocm-smi-Ausgabe",
                ),
                vram_used_bytes=Fact.maybe(
                    int(used * _MIB) if used is not None else None,
                    "VRAM-Belegung nicht in der rocm-smi-Ausgabe",
                ),
                vram_total_bytes=Fact.maybe(
                    int(total * _MIB) if total is not None else None,
                    "VRAM-Gesamtgroesse nicht in der rocm-smi-Ausgabe",
                ),
                temp_c=Fact.maybe(
                    as_float(pick(card, "temperature", "junction"))
                    or as_float(pick(card, "temperature", "edge")),
                    "Temperatursensor nicht ausgelesen",
                ),
                power_watts=Fact.maybe(
                    as_float(pick(card, "power")),
                    "Leistungsaufnahme nicht ausgelesen",
                ),
            )
        )
    if not samples:
        raise RuntimeError("rocm-smi lieferte keine Karten")
    return samples


def _probe_amdgpu_top() -> list[GpuSample]:
    """amdgpu_top laeuft auf Linux und Windows und ist die verlaesslichste
    Quelle fuer RDNA-Karten ohne vollen ROCm-Stack."""
    exe = shutil.which("amdgpu_top")
    if not exe:
        raise FileNotFoundError("amdgpu_top nicht im PATH")

    raw = _run([exe, "--json", "--single"])
    payload = json.loads(raw)
    devices = payload if isinstance(payload, list) else payload.get("devices", [payload])

    samples: list[GpuSample] = []
    for dev in devices:
        info = dev.get("DeviceName") or dev.get("device_name") or "AMD GPU"
        activity = dev.get("GRBM", {}) or dev.get("gpu_activity", {})
        gfx = activity.get("Graphics Pipe", activity.get("GFX", {}))
        util = gfx.get("value") if isinstance(gfx, dict) else gfx
        vram = dev.get("VRAM", {})
        used = (vram.get("Total VRAM Usage") or {}).get("value")
        total = (vram.get("Total VRAM") or {}).get("value")
        sensors = dev.get("Sensors", {})

        def sensor(key: str) -> float | None:
            entry = sensors.get(key)
            if isinstance(entry, dict):
                value = entry.get("value")
                return float(value) if isinstance(value, (int, float)) else None
            return None

        samples.append(
            GpuSample(
                name=str(info),
                vendor="amd",
                source="amdgpu_top",
                util_percent=Fact.maybe(
                    float(util) if isinstance(util, (int, float)) else None,
                    "Graphics-Pipe-Wert nicht in der Ausgabe",
                ),
                vram_used_bytes=Fact.maybe(
                    int(used) * _MIB if isinstance(used, (int, float)) else None,
                    "VRAM-Belegung nicht in der Ausgabe",
                ),
                vram_total_bytes=Fact.maybe(
                    int(total) * _MIB if isinstance(total, (int, float)) else None,
                    "VRAM-Gesamtgroesse nicht in der Ausgabe",
                ),
                temp_c=Fact.maybe(
                    sensor("Junction Temperature") or sensor("Edge Temperature"),
                    "Temperatursensor nicht in der Ausgabe",
                ),
                power_watts=Fact.maybe(
                    sensor("GFX Power"), "Leistungsaufnahme nicht in der Ausgabe"
                ),
            )
        )
    if not samples:
        raise RuntimeError("amdgpu_top lieferte keine Geraete")
    return samples


def _probe_nvidia_smi() -> list[GpuSample]:
    """Nur als Mitnahme - falls du irgendwann eine NVIDIA-Karte einsetzt."""
    exe = shutil.which("nvidia-smi")
    if not exe:
        raise FileNotFoundError("nvidia-smi nicht im PATH")

    raw = _run(
        [
            exe,
            "--query-gpu=name,utilization.gpu,memory.used,memory.total,temperature.gpu,power.draw",
            "--format=csv,noheader,nounits",
        ]
    )
    samples: list[GpuSample] = []
    for line in raw.strip().splitlines():
        cols = [c.strip() for c in line.split(",")]
        if len(cols) < 6:
            continue

        def num(index: int) -> float | None:
            try:
                return float(cols[index])
            except ValueError:
                return None

        used, total = num(2), num(3)
        samples.append(
            GpuSample(
                name=cols[0],
                vendor="nvidia",
                source="nvidia-smi",
                util_percent=Fact.maybe(num(1), "Wert von nvidia-smi nicht lesbar"),
                vram_used_bytes=Fact.maybe(
                    int(used * _MIB) if used is not None else None, "Wert nicht lesbar"
                ),
                vram_total_bytes=Fact.maybe(
                    int(total * _MIB) if total is not None else None, "Wert nicht lesbar"
                ),
                temp_c=Fact.maybe(num(4), "Wert nicht lesbar"),
                power_watts=Fact.maybe(num(5), "Wert nicht lesbar"),
            )
        )
    return samples


class _WindowsZaehlerProbe:
    """Leistungsindikatoren von Windows.

    Letzte in der Reihe, aber die erste, die auf einem Windows-Desktop ohne
    Zusatzinstallation etwas liefert: rocm-smi, amdgpu_top und nvidia-smi
    muessen erst eingerichtet werden. Die Abfrage bleibt zwischen den
    Messungen offen - ein Prozessstart pro Sekunde waere teurer als die
    Messung.
    """

    def __init__(self) -> None:
        self._zaehler: windows_gpu.WindowsGpuZaehler | None = None

    def __call__(self) -> list[GpuSample]:
        if self._zaehler is None:
            self._zaehler = windows_gpu.WindowsGpuZaehler()

        adapter = windows_gpu.adapter_lesen()
        if not adapter:
            raise RuntimeError("DXGI nennt keine Grafikkarte")

        auslastung = self._zaehler.auslastung()
        speicher = self._zaehler.belegter_speicher()

        proben: list[GpuSample] = []
        for luid, karte in adapter.items():
            # Adapter ohne jeden Messwert weglassen: eine zweite Karte, die
            # nichts tut und nichts belegt, ist keine Information.
            if luid not in auslastung and luid not in speicher:
                continue
            proben.append(
                GpuSample(
                    name=karte.name,
                    vendor=karte.vendor,
                    source="windows-counters",
                    util_percent=Fact.maybe(
                        round(auslastung[luid], 1) if luid in auslastung else None,
                        "kein Engine-Zaehler fuer diesen Adapter",
                    ),
                    vram_used_bytes=Fact.maybe(
                        speicher.get(luid),
                        "kein Speicherzaehler fuer diesen Adapter",
                    ),
                    vram_total_bytes=Fact.maybe(
                        karte.vram_total or None,
                        "DXGI nennt keine Gesamtgroesse",
                    ),
                    temp_c=Fact[float].unsupported_because(
                        "Windows-Leistungsindikatoren kennen keine Temperatur; "
                        "amdgpu_top oder nvidia-smi liefern sie"
                    ),
                    power_watts=Fact[float].unsupported_because(
                        "Windows-Leistungsindikatoren kennen keine Leistungsaufnahme; "
                        "amdgpu_top oder nvidia-smi liefern sie"
                    ),
                )
            )
        if not proben:
            raise RuntimeError("Leistungsindikatoren nennen keine Grafikkarte")
        return proben


_PROBES: list[tuple[str, Callable[[], list[GpuSample]]]] = [
    ("rocm-smi", _probe_rocm_smi),
    ("amdgpu_top", _probe_amdgpu_top),
    ("nvidia-smi", _probe_nvidia_smi),
    # Zuletzt: die anderen Quellen liefern zusaetzlich Temperatur und
    # Leistungsaufnahme. Wo sie fehlen, ist das hier besser als nichts.
    ("windows-counters", _WindowsZaehlerProbe()),
]


class TelemetryReader:
    def __init__(self) -> None:
        self._chosen: Callable[[], list[GpuSample]] | None = None
        self._failures: list[str] = []
        psutil.cpu_percent(interval=None)  # Referenzpunkt setzen

    def _gpus(self) -> tuple[list[GpuSample], str | None]:
        if self._chosen is not None:
            try:
                return self._chosen(), None
            except Exception as exc:  # noqa: BLE001 - Quelle neu suchen
                self._chosen = None
                self._failures = [f"{exc}"]

        errors: list[str] = []
        for name, probe in _PROBES:
            try:
                samples = probe()
            except Exception as exc:  # noqa: BLE001
                errors.append(f"{name}: {exc}")
                continue
            self._chosen = probe
            return samples, None

        self._failures = errors
        return [], "Keine GPU-Quelle nutzbar - " + "; ".join(errors)

    def sample(self) -> TelemetrySample:
        memory = psutil.virtual_memory()
        gpus, note = self._gpus()
        return TelemetrySample(
            at=datetime.now(timezone.utc),
            cpu_percent=Fact.of(psutil.cpu_percent(interval=None)),
            ram_used_bytes=Fact.of(memory.total - memory.available),
            ram_total_bytes=Fact.of(memory.total),
            gpus=gpus,
            gpu_note=note,
        )
