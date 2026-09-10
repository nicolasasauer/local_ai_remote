"""GPU-Werte unter Windows, ohne Fremdwerkzeug.

Windows misst die GPU laengst - der Task-Manager zeigt es. Die Zahlen stehen
in Leistungsindikatoren, und die sind ueber PDH direkt lesbar. Das ist die
verlaesslichste Quelle auf diesem System: sie funktioniert fuer AMD wie fuer
NVIDIA, sie braucht keine Installation, und sie kann nicht wie ``amdgpu_top``
zwischen Versionen ihr JSON-Schema aendern.

Zwei Windows-Schnittstellen zusammen ergeben ein vollstaendiges Bild:

* **PDH** liefert Auslastung und belegten Speicher, aufgeschluesselt nach
  Adapter-LUID.
* **DXGI** liefert zu derselben LUID den Namen der Karte und ihre
  Gesamtgroesse.

Ohne den zweiten Teil waere die Zuordnung geraten - und Raten ist in diesem
Projekt keine Option.

Was hier fehlt und ueber ``amdgpu_top`` oder ``nvidia-smi`` kaeme: Temperatur
und Leistungsaufnahme. Die tragen deshalb eine Begruendung statt einer Null.
"""

from __future__ import annotations

import ctypes
import sys
from ctypes import wintypes
from typing import Iterable, Iterator, NamedTuple

# ---------------------------------------------------------------------------
# DXGI: Name, Gesamtspeicher und LUID der Adapter
# ---------------------------------------------------------------------------


class _LUID(ctypes.Structure):
    _fields_ = [("LowPart", wintypes.DWORD), ("HighPart", wintypes.LONG)]


class _ADAPTER_DESC1(ctypes.Structure):
    _fields_ = [
        ("Description", wintypes.WCHAR * 128),
        ("VendorId", wintypes.UINT),
        ("DeviceId", wintypes.UINT),
        ("SubSysId", wintypes.UINT),
        ("Revision", wintypes.UINT),
        ("DedicatedVideoMemory", ctypes.c_size_t),
        ("DedicatedSystemMemory", ctypes.c_size_t),
        ("SharedSystemMemory", ctypes.c_size_t),
        ("AdapterLuid", _LUID),
        ("Flags", wintypes.UINT),
    ]


class _GUID(ctypes.Structure):
    _fields_ = [
        ("d1", wintypes.DWORD),
        ("d2", wintypes.WORD),
        ("d3", wintypes.WORD),
        ("d4", ctypes.c_ubyte * 8),
    ]


#: IID_IDXGIFactory1
_IID_FACTORY1 = _GUID(
    0x770AAE78,
    0xF26F,
    0x4DBA,
    (ctypes.c_ubyte * 8)(0xA8, 0x29, 0x25, 0x3C, 0x83, 0xD1, 0xB3, 0x87),
)

#: Index in der vtable. IDXGIFactory1 erbt IUnknown (3) + IDXGIObject (4) +
#: IDXGIFactory (5); EnumAdapters1 ist der erste eigene Eintrag.
_ENUM_ADAPTERS1 = 12
#: IDXGIAdapter1 erbt IUnknown (3) + IDXGIObject (4) + IDXGIAdapter (3).
_GET_DESC1 = 10

_SOFTWARE_ADAPTER = 0x2

_HERSTELLER = {0x1002: "amd", 0x10DE: "nvidia", 0x8086: "intel"}


class Adapter(NamedTuple):
    luid: str
    name: str
    vendor: str
    vram_total: int


def _luid_schluessel(hoch: int, niedrig: int) -> str:
    """Dieselbe Schreibweise wie in den PDH-Instanznamen.

    PDH schreibt Hex gross, DXGI liefert Zahlen - vergleichbar wird das erst
    nach einheitlicher Formatierung, deshalb hier klein und beim Vergleich
    ebenfalls klein.
    """
    return f"0x{hoch & 0xFFFFFFFF:08x}_0x{niedrig & 0xFFFFFFFF:08x}"


def adapter_lesen() -> dict[str, Adapter]:
    """Alle echten Grafikkarten, nach LUID."""
    dxgi = ctypes.WinDLL("dxgi")
    factory = ctypes.c_void_p()
    if dxgi.CreateDXGIFactory1(ctypes.byref(_IID_FACTORY1), ctypes.byref(factory)) != 0:
        return {}

    vtbl = ctypes.cast(
        factory, ctypes.POINTER(ctypes.POINTER(ctypes.c_void_p))
    ).contents
    enum = ctypes.WINFUNCTYPE(
        ctypes.c_long, ctypes.c_void_p, wintypes.UINT, ctypes.POINTER(ctypes.c_void_p)
    )(vtbl[_ENUM_ADAPTERS1])

    gefunden: dict[str, Adapter] = {}
    index = 0
    while True:
        roh = ctypes.c_void_p()
        if enum(factory, index, ctypes.byref(roh)) != 0:
            break
        index += 1

        av = ctypes.cast(roh, ctypes.POINTER(ctypes.POINTER(ctypes.c_void_p))).contents
        beschreiben = ctypes.WINFUNCTYPE(
            ctypes.c_long, ctypes.c_void_p, ctypes.POINTER(_ADAPTER_DESC1)
        )(av[_GET_DESC1])

        d = _ADAPTER_DESC1()
        if beschreiben(roh, ctypes.byref(d)) != 0:
            continue
        # "Microsoft Basic Render Driver" und aehnliche sind keine Karten.
        if d.Flags & _SOFTWARE_ADAPTER:
            continue

        schluessel = _luid_schluessel(d.AdapterLuid.HighPart, d.AdapterLuid.LowPart)
        gefunden[schluessel] = Adapter(
            luid=schluessel,
            name=d.Description,
            vendor=_HERSTELLER.get(d.VendorId, f"0x{d.VendorId:04x}"),
            vram_total=int(d.DedicatedVideoMemory),
        )
    return gefunden


# ---------------------------------------------------------------------------
# PDH: Auslastung und belegter Speicher
# ---------------------------------------------------------------------------

_PDH_FMT_DOUBLE = 0x00000200
_PDH_MORE_DATA = 0x800007D2

_PFAD_ENGINE = r"\GPU Engine(*)\Utilization Percentage"
_PFAD_SPEICHER = r"\GPU Adapter Memory(*)\Dedicated Usage"


class _Wert(ctypes.Union):
    _fields_ = [
        ("longValue", ctypes.c_long),
        ("doubleValue", ctypes.c_double),
        ("largeValue", ctypes.c_longlong),
        ("AnsiStringValue", ctypes.c_char_p),
    ]


class _Zaehlerwert(ctypes.Structure):
    _fields_ = [("CStatus", wintypes.DWORD), ("value", _Wert)]


class _Eintrag(ctypes.Structure):
    _fields_ = [("szName", wintypes.LPWSTR), ("FmtValue", _Zaehlerwert)]


def _luid_aus_instanz(name: str) -> str | None:
    """Die LUID aus einem Instanznamen.

    Engine-Instanzen heissen ``pid_5624_luid_0x..._0x..._phys_0_eng_0_engtype_3D``,
    Speicher-Instanzen ``luid_0x..._0x..._phys_0``. Gemeinsam ist der Teil
    zwischen ``luid_`` und ``_phys_``.
    """
    if "luid_" not in name:
        return None
    rest = name.split("luid_", 1)[1]
    return rest.split("_phys_", 1)[0].lower() if "_phys_" in rest else None


def auslastung_aus_zaehlern(paare: Iterable[tuple[str, float]]) -> dict[str, float]:
    """Pro Adapter der Wert, den auch der Task-Manager zeigt.

    Windows misst je Engine (3D, Compute, Copy, Video ...) **und** je Prozess.
    Innerhalb einer Engine-Art werden die Prozesse addiert, ueber die Arten
    hinweg wird das Maximum genommen - eine Summe ueber alle Arten koennte
    weit ueber 100 % liegen und waere keine Auslastung mehr.
    """
    je_art: dict[tuple[str, str], float] = {}
    for name, wert in paare:
        if "_engtype_" not in name:
            continue
        luid = _luid_aus_instanz(name)
        if not luid:
            continue
        art = name.split("_engtype_")[-1]
        je_art[(luid, art)] = je_art.get((luid, art), 0.0) + wert

    hoechste: dict[str, float] = {}
    for (luid, _art), wert in je_art.items():
        hoechste[luid] = max(hoechste.get(luid, 0.0), wert)
    return {luid: min(wert, 100.0) for luid, wert in hoechste.items()}


def speicher_aus_zaehlern(paare: Iterable[tuple[str, float]]) -> dict[str, int]:
    je_adapter: dict[str, int] = {}
    for name, wert in paare:
        luid = _luid_aus_instanz(name)
        if luid:
            je_adapter[luid] = je_adapter.get(luid, 0) + int(wert)
    return je_adapter


class WindowsGpuZaehler:
    """Haelt die PDH-Abfragen offen.

    Ein Prozessstart pro Sekunde waere teurer als die Messung selbst; PDH
    kostet so nur einen Funktionsaufruf. Die erste Sammlung dient als
    Bezugspunkt - Auslastung ist eine Rate und braucht zwei Messpunkte.
    """

    def __init__(self) -> None:
        if sys.platform != "win32":
            raise OSError("Leistungsindikatoren gibt es nur unter Windows")
        self._pdh = ctypes.WinDLL("pdh")
        self._engine = self._oeffnen(_PFAD_ENGINE)
        self._speicher = self._oeffnen(_PFAD_SPEICHER)
        # Bezugspunkt setzen, damit der erste echte Aufruf schon Werte hat.
        # Direkt sammeln statt ueber `_sammeln`: das ist ein Generator, und
        # ein nicht ausgelesener Generator fuehrt gar nichts aus - der
        # Bezugspunkt fehlte dann, und die erste Auslastung waere 0 %.
        self._bezugspunkt()

    def _bezugspunkt(self) -> None:
        for abfrage, _ in (self._engine, self._speicher):
            self._pdh.PdhCollectQueryData(abfrage)

    def _oeffnen(self, pfad: str) -> tuple[wintypes.HANDLE, wintypes.HANDLE]:
        abfrage = wintypes.HANDLE()
        if self._pdh.PdhOpenQueryW(None, 0, ctypes.byref(abfrage)) != 0:
            raise OSError("PdhOpenQuery fehlgeschlagen")
        zaehler = wintypes.HANDLE()
        # Die englische Variante: auf einem deutschen Windows heissen die
        # Zaehler anders, und der Pfad wuerde sonst nicht gefunden.
        ergebnis = self._pdh.PdhAddEnglishCounterW(
            abfrage, pfad, 0, ctypes.byref(zaehler)
        )
        if ergebnis != 0:
            raise OSError(f"Zaehler '{pfad}' nicht verfuegbar (0x{ergebnis & 0xFFFFFFFF:08x})")
        return abfrage, zaehler

    def _sammeln(
        self, paar: tuple[wintypes.HANDLE, wintypes.HANDLE]
    ) -> Iterator[tuple[str, float]]:
        abfrage, zaehler = paar
        self._pdh.PdhCollectQueryData(abfrage)

        groesse = wintypes.DWORD(0)
        anzahl = wintypes.DWORD(0)
        ergebnis = self._pdh.PdhGetFormattedCounterArrayW(
            zaehler, _PDH_FMT_DOUBLE, ctypes.byref(groesse), ctypes.byref(anzahl), None
        )
        if (ergebnis & 0xFFFFFFFF) != _PDH_MORE_DATA or not anzahl.value:
            return

        puffer = ctypes.create_string_buffer(groesse.value)
        if self._pdh.PdhGetFormattedCounterArrayW(
            zaehler,
            _PDH_FMT_DOUBLE,
            ctypes.byref(groesse),
            ctypes.byref(anzahl),
            puffer,
        ) != 0:
            return

        felder = ctypes.cast(
            puffer, ctypes.POINTER(_Eintrag * anzahl.value)
        ).contents
        for feld in felder:
            if feld.szName:
                yield feld.szName, feld.FmtValue.value.doubleValue

    def auslastung(self) -> dict[str, float]:
        return auslastung_aus_zaehlern(self._sammeln(self._engine))

    def belegter_speicher(self) -> dict[str, int]:
        return speicher_aus_zaehlern(self._sammeln(self._speicher))
