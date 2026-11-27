"""Ladeoptionen in LM Studio vergleichen: wie schnell, wie viel im System-RAM.

Laedt ein Modell nacheinander mit verschiedenen Optionen, misst jedes Mal
Tokens pro Sekunde, Zeit bis zum ersten Token und - unter Windows - wie viel
in VRAM und geteiltem GPU-Speicher landet. Am Ende steht eine Tabelle, die
zeigt, welche Einstellung auf diesem Rechner am schnellsten ist.

Aufruf auf dem Desktop, im Projektordner, mit laufendem LM Studio:

    pip install -r tools/requirements.txt
    python -m tools.ladetest --modell thinkingmachines/inkling-2-mini

Weitere Quantisierungen desselben Modells (z. B. Q3) mit ``--auch``.
Ergebnisse landen zusaetzlich als JSON neben dem Aufruf.

Grenzen, ehrlich:

* Die MoE-Auslagerung (``numCpuExpertLayersRatio``) kennt das Python-SDK
  noch nicht; sie wird hier als Feld nachgereicht, unter dem Namen, den das
  JavaScript-SDK von LM Studio verwendet. Nimmt LM Studio sie nicht an, sieht
  man das in der Tabelle: dieselben Werte wie ohne. Das Skript meldet das.
* LM Studio und Bionic koennen nicht gleichzeitig laufen.
* Speicherwerte gibt es nur unter Windows (Leistungsindikatoren, wie im
  Task-Manager). Anderswo laeuft der Test, aber ohne diese Spalten.
"""

from __future__ import annotations

import argparse
import json
import statistics
import sys
import time
from dataclasses import asdict, dataclass, field
from datetime import datetime
from pathlib import Path
from typing import Any, Callable

GIB = 1024**3

#: Server-Schluessel der MoE-Auslagerung, wie ihn lmstudio-js setzt
#: (packages/lms-kv-config/src/conversion/llmLoadModelConfig.ts).
MOE_SCHLUESSEL = "llm.load.numCpuExpertLayersRatio"
#: Unter diesem Namen steht der Wert in den Varianten; vor der Uebergabe ans
#: SDK wird er herausgenommen und als eigenes Feld angehaengt.
MOE_OPTION = "numCpuExpertLayersRatio"

PROMPT = (
    "Schreibe eine Python-Funktion, die eine Liste von Datumsangaben im Format "
    "TT.MM.JJJJ einliest, ungueltige Eintraege mit Begruendung meldet und die "
    "gueltigen aufsteigend sortiert zurueckgibt. Erklaere danach in drei Saetzen, "
    "welche Randfaelle du bedacht hast."
)


# ---------------------------------------------------------------------------
# Varianten
# ---------------------------------------------------------------------------


@dataclass
class Variante:
    name: str
    beschreibung: str
    config: dict[str, Any]
    modell: str | None = None  # None: das Hauptmodell


def varianten(modell: str, kontext: int, auch: list[str]) -> list[Variante]:
    """Die Standardreihe: vom Lieferzustand zu den einzelnen Hebeln.

    Ab B haben alle dasselbe Kontextfenster - sonst vergliche man Aepfel mit
    Birnen, denn ein groesserer Kontext belegt mehr Speicher.
    """
    basis = {"contextLength": kontext, "gpu": {"ratio": "max"}}
    sparsam = {
        **basis,
        "flashAttention": True,
        "llamaKCacheQuantizationType": "q8_0",
        "llamaVCacheQuantizationType": "q8_0",
    }
    reihe = [
        Variante("A", "wie LM Studio ohne Vorgaben laedt", {}),
        Variante("B", "alles auf die GPU", basis),
        Variante("C", "B + Flash Attention + KV-Cache q8_0", sparsam),
        Variante(
            "D",
            "C + strikte VRAM-Grenze (LM Studio deckelt selbst)",
            {**sparsam, "gpuStrictVramCap": True},
        ),
    ]
    for anteil in (0.25, 0.5, 0.75):
        reihe.append(
            Variante(
                f"E{int(anteil * 100)}",
                f"C + {int(anteil * 100)} % der MoE-Experten-Schichten im RAM",
                {**sparsam, MOE_OPTION: anteil},
            )
        )
    for i, weiteres in enumerate(auch, start=1):
        reihe.append(Variante(f"F{i}", f"C mit {weiteres}", dict(sparsam), weiteres))
    for v in reihe:
        v.modell = v.modell or modell
    return reihe


# ---------------------------------------------------------------------------
# MoE-Feld am SDK vorbei
# ---------------------------------------------------------------------------


def moe_durchreichen(original: Callable[..., Any]) -> Callable[..., Any]:
    """Umhuellt ``load_config_to_kv_config_stack`` des SDK.

    Das SDK lehnt Felder ab, die es nicht kennt. Der Wert wird deshalb vorher
    herausgenommen und danach als Feld der obersten Schicht angehaengt -
    genau dort, wo das SDK auch alle anderen Ladeoptionen ablegt.
    """

    def huelle(config: Any, config_type: Any) -> Any:
        anteil = None
        if isinstance(config, dict) and MOE_OPTION in config:
            config = dict(config)
            anteil = config.pop(MOE_OPTION)
        stapel = original(config, config_type)
        if anteil is None:
            return stapel
        roh = stapel.to_dict()
        roh["layers"][0]["config"]["fields"].append(
            {"key": MOE_SCHLUESSEL, "value": anteil}
        )
        return type(stapel)._from_api_dict(roh)

    return huelle


# ---------------------------------------------------------------------------
# Speicher messen (nur Windows)
# ---------------------------------------------------------------------------


@dataclass
class Speicher:
    vram: int | None = None
    geteilt: int | None = None
    karte: str | None = None


class Speichermesser:
    """Die Karte mit dem meisten eigenen VRAM - dieselbe Wahl wie die App."""

    def __init__(self) -> None:
        self.grund: str | None = None
        self._zaehler = None
        if sys.platform != "win32":
            self.grund = "Speicherwerte nur unter Windows"
            return
        try:
            from gateway import windows_gpu

            self._wg = windows_gpu
            self._zaehler = windows_gpu.WindowsGpuZaehler()
        except Exception as exc:  # noqa: BLE001 - Test laeuft trotzdem
            self.grund = f"Leistungsindikatoren nicht lesbar: {exc}"

    def messen(self) -> Speicher:
        if self._zaehler is None:
            return Speicher()
        adapter = self._wg.adapter_lesen()
        if not adapter:
            return Speicher()
        luid, karte = max(adapter.items(), key=lambda e: e[1].vram_total)
        geteilt = self._zaehler.geteilter_speicher() or {}
        return Speicher(
            vram=self._zaehler.belegter_speicher().get(luid),
            geteilt=geteilt.get(luid),
            karte=karte.name,
        )


# ---------------------------------------------------------------------------
# Ein Durchlauf
# ---------------------------------------------------------------------------


@dataclass
class Ergebnis:
    variante: str
    beschreibung: str
    modell: str
    tok_s: float | None = None
    ttft_s: float | None = None
    gpu_schichten: float | None = None
    ladezeit_s: float | None = None
    vram_gib: float | None = None
    geteilt_gib: float | None = None
    kontext: int | None = None
    fehler: str | None = None
    laeufe: list[float] = field(default_factory=list)
    #: Was LM Studio tatsaechlich angewendet hat - eine angeforderte Option,
    #: die hier fehlt, wurde ignoriert.
    angewendet: dict[str, Any] = field(default_factory=dict)


def _gib(wert: int | None) -> float | None:
    return None if wert is None else round(wert / GIB, 2)


def _differenz(nach: int | None, vor: int | None) -> int | None:
    if nach is None or vor is None:
        return None
    return max(nach - vor, 0)


def durchlauf(
    client: Any,
    variante: Variante,
    messer: Speichermesser,
    tokens: int,
    wiederholungen: int,
) -> Ergebnis:
    erg = Ergebnis(variante.name, variante.beschreibung, variante.modell or "?")
    vorher = messer.messen()
    beginn = time.monotonic()
    try:
        modell = client.llm.load_new_instance(
            variante.modell, config=variante.config, ttl=None
        )
    except Exception as exc:  # noqa: BLE001 - naechste Variante
        erg.fehler = f"Laden abgelehnt: {exc}"[:300]
        return erg
    erg.ladezeit_s = round(time.monotonic() - beginn, 1)

    try:
        time.sleep(2)  # Speicher setzt sich nach dem Laden
        nachher = messer.messen()
        erg.vram_gib = _gib(_differenz(nachher.vram, vorher.vram))
        erg.geteilt_gib = _gib(_differenz(nachher.geteilt, vorher.geteilt))
        try:
            erg.kontext = modell.get_context_length()
            erg.angewendet = modell.get_load_config().to_dict()
        except Exception:  # noqa: BLE001 - nur Anzeige
            pass

        einstellungen = {"maxTokens": tokens, "temperature": 0.0}
        modell.respond("Antworte nur mit OK.", config={"maxTokens": 8})  # Aufwaermen
        ttfts: list[float] = []
        for _ in range(wiederholungen):
            antwort = modell.respond(PROMPT, config=einstellungen)
            stats = antwort.stats
            if stats.tokens_per_second is not None:
                erg.laeufe.append(round(stats.tokens_per_second, 1))
            if stats.time_to_first_token_sec is not None:
                ttfts.append(stats.time_to_first_token_sec)
            erg.gpu_schichten = stats.num_gpu_layers
        if erg.laeufe:
            erg.tok_s = round(statistics.median(erg.laeufe), 1)
        if ttfts:
            erg.ttft_s = round(statistics.median(ttfts), 2)
    except Exception as exc:  # noqa: BLE001
        erg.fehler = f"Antwort fehlgeschlagen: {exc}"[:300]
    finally:
        try:
            modell.unload()
        except Exception:  # noqa: BLE001
            pass
        time.sleep(2)
    return erg


# ---------------------------------------------------------------------------
# Auswertung
# ---------------------------------------------------------------------------


def tabelle(ergebnisse: list[Ergebnis]) -> str:
    def zelle(wert: Any, fmt: str = "{}") -> str:
        return "—" if wert is None else fmt.format(wert)

    zeilen = [
        "| Var. | tok/s | 1. Token | VRAM | System-RAM | GPU-Schichten | Kontext | Beschreibung |",
        "|---|---:|---:|---:|---:|---:|---:|---|",
    ]
    for e in ergebnisse:
        if e.fehler:
            zeilen.append(f"| {e.variante} | ✗ | | | | | | {e.beschreibung} — {e.fehler} |")
            continue
        zeilen.append(
            f"| {e.variante} | {zelle(e.tok_s)} | {zelle(e.ttft_s, '{} s')} "
            f"| {zelle(e.vram_gib, '{} GiB')} | {zelle(e.geteilt_gib, '{} GiB')} "
            f"| {zelle(e.gpu_schichten)} | {zelle(e.kontext)} | {e.beschreibung} |"
        )
    return "\n".join(zeilen)


def hinweise(ergebnisse: list[Ergebnis]) -> list[str]:
    """Was sich aus der Tabelle ablesen laesst - und was ihr misstraut."""
    out: list[str] = []
    gut = [e for e in ergebnisse if e.tok_s is not None]
    if gut:
        beste = max(gut, key=lambda e: e.tok_s or 0)
        out.append(f"Am schnellsten: {beste.variante} ({beste.tok_s} tok/s) — {beste.beschreibung}.")

    nach_name = {e.variante: e for e in ergebnisse}
    c = nach_name.get("C")
    moe = [e for e in ergebnisse if e.variante.startswith("E") and e.tok_s is not None]
    if c and c.tok_s is not None and moe:
        # Mit Toleranz: zwei Ladevorgaenge mit identischer Einstellung
        # unterscheiden sich um ein paar hundert MB Rechenpuffer.
        def nah(a: float | None, b: float | None) -> bool:
            return a is not None and b is not None and abs(a - b) < 0.3

        gleich = all(
            nah(e.vram_gib, c.vram_gib) and nah(e.geteilt_gib, c.geteilt_gib)
            for e in moe
        )
        if gleich and c.vram_gib is not None:
            out.append(
                "Die MoE-Varianten belegen exakt so viel Speicher wie C — LM Studio "
                "hat die Auslagerung vermutlich nicht angenommen. In der App unter "
                "den Ladeoptionen von Hand setzen und vergleichen."
            )
    for e in gut:
        if e.geteilt_gib is not None and e.geteilt_gib >= 1:
            out.append(
                f"{e.variante}: {e.geteilt_gib} GiB im System-RAM — dort liest die "
                "GPU über PCIe."
            )
    return out


def main(argv: list[str] | None = None) -> int:
    p = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    p.add_argument("--modell", required=True, help="Modellschluessel wie in LM Studio")
    p.add_argument("--auch", action="append", default=[],
                   help="weitere Modellschluessel, z. B. eine Q3-Variante (mehrfach)")
    p.add_argument("--kontext", type=int, default=32768)
    p.add_argument("--tokens", type=int, default=256, help="Antwortlaenge pro Lauf")
    p.add_argument("--wiederholungen", type=int, default=2)
    p.add_argument("--nur", help="nur diese Varianten, z. B. A,C,E50")
    p.add_argument("--alle-entladen", action="store_true",
                   help="andere geladene Modelle vorher entladen")
    p.add_argument("--host", help="LM-Studio-Adresse, Standard: automatisch")
    args = p.parse_args(argv)

    try:
        import lmstudio
        from lmstudio import json_api
    except ImportError:
        print("Das LM-Studio-SDK fehlt: pip install -r tools/requirements.txt")
        return 2

    json_api.load_config_to_kv_config_stack = moe_durchreichen(
        json_api.load_config_to_kv_config_stack
    )

    client = lmstudio.Client(args.host) if args.host else lmstudio.Client()
    geladen = list(client.llm.list_loaded())
    if geladen:
        namen = ", ".join(m.identifier for m in geladen)
        if not args.alle_entladen:
            print(f"Schon geladen: {namen}")
            print("Diese belegen VRAM und verfaelschen die Messung. Mit "
                  "--alle-entladen werden sie vorher entladen.")
            return 3
        for m in geladen:
            m.unload()
        time.sleep(3)

    reihe = varianten(args.modell, args.kontext, args.auch)
    if args.nur:
        wahl = {n.strip().upper() for n in args.nur.split(",")}
        reihe = [v for v in reihe if v.name.upper() in wahl]

    messer = Speichermesser()
    if messer.grund:
        print(f"Hinweis: {messer.grund}")

    ergebnisse: list[Ergebnis] = []
    for v in reihe:
        print(f"[{v.name}] {v.beschreibung} …", flush=True)
        e = durchlauf(client, v, messer, args.tokens, args.wiederholungen)
        print(f"      {e.fehler or f'{e.tok_s} tok/s, {e.geteilt_gib} GiB im System-RAM'}")
        ergebnisse.append(e)

    print()
    print(tabelle(ergebnisse))
    print()
    for h in hinweise(ergebnisse):
        print(f"• {h}")

    datei = Path(f"ladetest-{datetime.now():%Y%m%d-%H%M}.json")
    datei.write_text(
        json.dumps([asdict(e) for e in ergebnisse], indent=2, ensure_ascii=False),
        encoding="utf-8",
    )
    print(f"\nRohdaten: {datei}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
