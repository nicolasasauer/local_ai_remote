"""Erzeugt die Quellbilder fuer das App-Icon.

Warum ein Skript statt fertiger PNGs im Repo: die Plattformordner sind
generiert, und ein Icon, das nur dort liegt, waere beim naechsten
``flutter create`` weg. Hier liegt die Quelle, ``flutter_launcher_icons``
macht daraus die Groessen fuer Android und Windows.

Das Zeichen benutzt die Farblogik der App, nicht Dekoration:

* **Bernstein** - ein Modell liegt im Speicher (der Chip).
* **Tuerkis**   - eine laufende Messung (der Puls, der hindurchgeht).

Zusammen ist das die App in einem Bild: auf dem Desktop liegt ein Modell im
Speicher, und man sieht ihm bei der Arbeit zu.

    python tool/icon_erzeugen.py
    dart run flutter_launcher_icons
"""

from __future__ import annotations

import pathlib

from PIL import Image, ImageDraw

# Aus lib/src/theme.dart, damit Icon und Oberflaeche dieselben Farben tragen.
BASE = (0x0F, 0x14, 0x18, 255)
AMBER = (0xE9, 0xA1, 0x3B, 255)
TEAL = (0x4F, 0xC3, 0xB0, 255)

KANTE = 1024
#: PIL zeichnet ohne Kantenglaettung. Vierfach zeichnen und verkleinern
#: erledigt das zuverlaessiger als jede Nachbearbeitung.
UEBER = 4


def _zeichne_marke(zeichner: ImageDraw.ImageDraw, mitte: float, groesse: float) -> None:
    """Chip mit Anschluessen und einem Puls darin.

    ``groesse`` ist die Kantenlaenge des Chipkoerpers; die Anschluesse ragen
    darueber hinaus.
    """
    halb = groesse / 2
    strich = groesse * 0.085
    links, oben = mitte - halb, mitte - halb
    rechts, unten = mitte + halb, mitte + halb

    # Chipkoerper
    zeichner.rounded_rectangle(
        [links, oben, rechts, unten],
        radius=groesse * 0.17,
        outline=AMBER,
        width=int(strich),
    )

    # Anschluesse: drei je Seite. Kurz und dick, damit sie auch bei 48 px
    # nicht zu Staub zerfallen.
    laenge = groesse * 0.13
    dicke = int(groesse * 0.075)
    for anteil in (0.28, 0.5, 0.72):
        pos = oben + groesse * anteil
        zeichner.line([links - laenge, pos, links, pos], fill=AMBER, width=dicke)
        zeichner.line([rechts, pos, rechts + laenge, pos], fill=AMBER, width=dicke)
        quer = links + groesse * anteil
        zeichner.line([quer, oben - laenge, quer, oben], fill=AMBER, width=dicke)
        zeichner.line([quer, unten, quer, unten + laenge], fill=AMBER, width=dicke)

    # Der Puls. Bewusst asymmetrisch - eine gleichmaessige Zickzacklinie sieht
    # aus wie ein Muster, nicht wie eine Messung.
    b = groesse
    punkte = [
        (mitte - b * 0.30, mitte),
        (mitte - b * 0.15, mitte),
        (mitte - b * 0.06, mitte - b * 0.22),
        (mitte + b * 0.04, mitte + b * 0.18),
        (mitte + b * 0.13, mitte),
        (mitte + b * 0.30, mitte),
    ]
    zeichner.line(punkte, fill=TEAL, width=int(groesse * 0.075), joint="curve")
    # Runde Enden: `joint` glaettet nur die Ecken, nicht die Abschluesse.
    r = groesse * 0.037
    for x, y in (punkte[0], punkte[-1]):
        zeichner.ellipse([x - r, y - r, x + r, y + r], fill=TEAL)


def _leinwand() -> tuple[Image.Image, ImageDraw.ImageDraw, int]:
    kante = KANTE * UEBER
    bild = Image.new("RGBA", (kante, kante), (0, 0, 0, 0))
    return bild, ImageDraw.Draw(bild), kante


def volles_icon() -> Image.Image:
    """Fuer Systeme, die kein adaptives Icon kennen: Hintergrund inklusive."""
    bild, zeichner, kante = _leinwand()
    zeichner.rounded_rectangle(
        [0, 0, kante - 1, kante - 1], radius=kante * 0.22, fill=BASE
    )
    _zeichne_marke(zeichner, kante / 2, kante * 0.46)
    return bild.resize((KANTE, KANTE), Image.LANCZOS)


def vordergrund() -> Image.Image:
    """Fuer adaptive Icons: nur das Zeichen, mit Rand.

    Android beschneidet den Vordergrund je nach Geraet zu Kreis, Quadrat oder
    Kleeblatt. Nur die inneren zwei Drittel sind sicher sichtbar - deshalb
    faellt das Zeichen hier deutlich kleiner aus.
    """
    bild, zeichner, kante = _leinwand()
    _zeichne_marke(zeichner, kante / 2, kante * 0.34)
    return bild.resize((KANTE, KANTE), Image.LANCZOS)


def main() -> None:
    ziel = pathlib.Path(__file__).resolve().parent.parent / "assets" / "icon"
    ziel.mkdir(parents=True, exist_ok=True)

    volles_icon().save(ziel / "icon.png")
    vordergrund().save(ziel / "icon_foreground.png")
    print(f"geschrieben: {ziel / 'icon.png'}")
    print(f"geschrieben: {ziel / 'icon_foreground.png'}")
    print("weiter mit: dart run flutter_launcher_icons")


if __name__ == "__main__":
    main()
