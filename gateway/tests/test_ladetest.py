"""Das Benchmark-Skript fuer LM-Studio-Ladeoptionen (tools/ladetest.py).

LM Studio selbst laeuft hier nicht; geprueft wird, was ohne es pruefbar ist:
welche Varianten entstehen, dass die MoE-Option am SDK vorbei ankommt, und
dass die Auswertung nichts behauptet, was die Messung nicht hergibt.
"""

from __future__ import annotations

from tools.ladetest import (
    MOE_OPTION,
    MOE_SCHLUESSEL,
    Ergebnis,
    hinweise,
    moe_durchreichen,
    tabelle,
    varianten,
)


class TestVarianten:
    def test_ab_b_gleicher_kontext(self):
        reihe = varianten("m", 32768, [])
        assert reihe[0].name == "A" and reihe[0].config == {}
        for v in reihe[1:]:
            assert v.config["contextLength"] == 32768

    def test_weitere_quantisierung_bekommt_eigenes_modell(self):
        reihe = varianten("m-q4", 8192, ["m-q3"])
        f = [v for v in reihe if v.name == "F1"][0]
        assert f.modell == "m-q3"
        assert all(v.modell == "m-q4" for v in reihe if v.name != "F1")

    def test_moe_varianten_tragen_den_anteil(self):
        e = [v for v in varianten("m", 8192, []) if v.name.startswith("E")]
        assert [v.config[MOE_OPTION] for v in e] == [0.25, 0.5, 0.75]


class FakeStapel:
    def __init__(self, roh):
        self.roh = roh

    def to_dict(self):
        return self.roh

    @classmethod
    def _from_api_dict(cls, roh):
        return cls(roh)


class TestMoeDurchreichen:
    def _original(self, gesehen):
        def original(config, config_type):
            gesehen.append(config)
            felder = [{"key": f"llm.load.{k}", "value": v} for k, v in config.items()]
            return FakeStapel({"layers": [{"layerName": "apiOverride",
                                           "config": {"fields": felder}}]})
        return original

    def test_option_geht_nicht_ans_sdk_aber_ans_ende_des_stapels(self):
        gesehen = []
        huelle = moe_durchreichen(self._original(gesehen))
        stapel = huelle({"contextLength": 8192, MOE_OPTION: 0.5}, object)
        # Das SDK haette den unbekannten Schluessel abgelehnt.
        assert MOE_OPTION not in gesehen[0]
        felder = stapel.roh["layers"][0]["config"]["fields"]
        assert {"key": MOE_SCHLUESSEL, "value": 0.5} in felder

    def test_ohne_option_unveraendert(self):
        gesehen = []
        huelle = moe_durchreichen(self._original(gesehen))
        config = {"contextLength": 8192}
        huelle(config, object)
        assert gesehen[0] is config


def _e(name, tok, vram=10.0, geteilt=0.0, fehler=None):
    return Ergebnis(name, f"Variante {name}", "m", tok_s=tok, vram_gib=vram,
                    geteilt_gib=geteilt, fehler=fehler)


class TestAuswertung:
    def test_schnellste_wird_genannt(self):
        h = hinweise([_e("A", 12.0, geteilt=8.0), _e("C", 30.0)])
        assert any("C (30.0 tok/s)" in x for x in h)
        assert any(x.startswith("A: 8.0 GiB im System-RAM") for x in h)

    def test_wirkungslose_moe_option_wird_gemeldet(self):
        h = hinweise([_e("C", 20.0), _e("E50", 20.5)])
        assert any("nicht angenommen" in x for x in h)

    def test_wirksame_moe_option_kein_verdacht(self):
        h = hinweise([_e("C", 20.0, geteilt=6.0), _e("E50", 25.0, vram=8.0)])
        assert not any("nicht angenommen" in x for x in h)

    def test_fehler_steht_in_der_tabelle(self):
        t = tabelle([_e("D", None, fehler="Laden abgelehnt: kaputt")])
        assert "Laden abgelehnt: kaputt" in t
